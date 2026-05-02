defmodule BoomLooper.Tools.Container.ProbeHttp do
  use BoomLooper.Tool,
    name: "probe_http",
    description:
      "Probe an HTTP endpoint from the HOST'S perspective — the same vantage point the eval runner uses. ALWAYS use this to verify the dev server is reachable. Without args, finds the workspace's published host port and probes /. Pass `port` to override which container port to look up, or `path` to hit /up, /health, etc. The response includes the exact URL probed, status code, body preview, and (on failure) a per-stack diagnosis of likely causes.",
    busy_words: ["probing", "pinging the server", "checking if it's alive"],
    params: [
      agent_id: {:string, required: true},
      port:
        {:integer,
         description:
           "Container port to look up (e.g. 3000). Default: probe whatever's published on workspace or dev container."},
      path:
        {:string,
         description:
           "Request path. Default: '/'. Common alternatives: '/up' (Rails), '/health', '/healthz'."}
    ]

  alias BoomLooper.Docker
  alias BoomLooper.Tools.Container.Helpers
  alias BoomLooper.Tools.Container.ProbeFormatter

  def execute(%{agent_id: agent_id} = params, _assigns) do
    container_port = Map.get(params, :port)
    path = Map.get(params, :path, "/")

    with {:ok, workspace_id} <- Helpers.agent_workspace_id(agent_id) do
      project_name = BoomLooper.Compose.project_name(workspace_id)
      candidates = discover_dev_host_ports(project_name, container_port)

      case try_probe_candidates(candidates, path, project_name) do
        {:ok, host_port, status, body, container_name} ->
          {:ok,
           ProbeFormatter.format_probe_success(host_port, container_name, path, status, body)}

        {:error, :no_ports} ->
          {:ok, ProbeFormatter.format_probe_no_ports(project_name)}

        {:error, {:no_response, attempted, container_states}} ->
          {:ok, ProbeFormatter.format_probe_no_response(attempted, path, container_states)}
      end
    end
  end

  defp discover_dev_host_ports(project_name, nil) do
    workspace_name = "#{project_name}-workspace-1"
    dev_name = "#{project_name}-dev-1"

    for name <- [workspace_name, dev_name],
        container_running?(name),
        {container_port, host_port} <- Docker.container_ports(name) do
      {name, container_port, host_port}
    end
  end

  defp discover_dev_host_ports(project_name, container_port) do
    target = to_string(container_port)
    workspace_name = "#{project_name}-workspace-1"
    dev_name = "#{project_name}-dev-1"

    for name <- [workspace_name, dev_name],
        container_running?(name),
        {cport, host_port} <- Docker.container_ports(name),
        cport == target do
      {name, cport, host_port}
    end
  end

  defp try_probe_candidates([], _path, _project_name), do: {:error, :no_ports}

  defp try_probe_candidates(candidates, path, project_name) do
    {results, _} =
      Enum.reduce_while(candidates, {[], nil}, fn {container, container_port, host_port},
                                                  {acc, _} ->
        url = "http://localhost:#{host_port}#{path}"

        case http_get(url) do
          {:ok, status, body} ->
            {:halt, {{:found, host_port, container, status, body}, nil}}

          {kind, detail} when kind in [:refused, :timeout, :other] ->
            attempt = {container, container_port, host_port, kind, detail}
            {:cont, {[attempt | acc], nil}}
        end
      end)

    case results do
      {:found, host_port, container, status, body} ->
        {:ok, host_port, status, body, container}

      attempted when is_list(attempted) ->
        states =
          for {container, _, _, _, _} <- Enum.uniq_by(attempted, fn {c, _, _, _, _} -> c end),
              into: %{} do
            {container, container_running?(container)}
          end

        _ = project_name
        {:error, {:no_response, Enum.reverse(attempted), states}}
    end
  end

  defp container_running?(name), do: Docker.container_running?(name)

  # Distinguish connect-refused (port not bound / wrong address) from
  # slow-response (app still booting) so the formatter can give the
  # agent an accurate diagnosis. The previous single `:error` catch
  # mislabeled every slow response as "connection refused" and sent
  # the agent chasing 127.0.0.1 binding bugs when the real issue was
  # cold-start latency (php-fpm first request, Rails asset precompile).
  #
  # Timeouts: 30s total, 5s connect. A refused connection errors in
  # milliseconds regardless of these; only apps that accept the TCP
  # handshake but are slow to produce bytes hit the total timeout.
  defp http_get(url) do
    :inets.start()
    :ssl.start()

    case :httpc.request(
           :get,
           {String.to_charlist(url), []},
           [timeout: 30_000, connect_timeout: 5_000],
           body_format: :binary
         ) do
      {:ok, {{_, status, _}, _headers, body}} ->
        {:ok, status, String.slice(to_string(body), 0..600)}

      {:error, {:failed_connect, details}} ->
        classify_failed_connect(details)

      {:error, reason} when reason in [:timeout, :etimedout] ->
        {:timeout,
         "TCP connected but no HTTP response in 30s — likely a cold start (php-fpm first request, Rails asset precompile). Wait and retry."}

      {:error, reason} ->
        {:other, "HTTP probe errored: #{inspect(reason)}"}
    end
  end

  # :httpc wraps failures as `{:failed_connect, [{:to_address, _}, {:inet, _, reason}]}`.
  # The leaf reason atom tells us what actually happened.
  defp classify_failed_connect(details) do
    reason =
      Enum.find_value(details, fn
        {:inet, _, r} -> r
        {:error, r} -> r
        _ -> nil
      end)

    case reason do
      :econnrefused ->
        {:refused,
         "port not accepting TCP — unbound, wrong address, or bound to 127.0.0.1 inside the container"}

      :ehostunreach ->
        {:refused, "host unreachable — Docker network likely misconfigured"}

      t when t in [:timeout, :etimedout] ->
        {:timeout,
         "TCP connect timed out after 5s — port probably not bound; if the container just came up, try again in 10–30s"}

      other ->
        {:other, "connect failed: #{inspect(other)}"}
    end
  end
end
