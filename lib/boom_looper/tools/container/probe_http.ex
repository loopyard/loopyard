defmodule BoomLooper.Tools.Container.ProbeHttp do
  @moduledoc false

  alias BoomLooper.Docker
  alias BoomLooper.Tools.Container.Helpers

  def __tool_name__, do: "probe_http"

  def __description__,
    do:
      "Probe an HTTP endpoint from the HOST'S perspective — the same vantage point the eval runner uses. ALWAYS use this to verify the dev server is reachable. Without args, finds the workspace's published host port and probes /. Pass `port` to override which container port to look up, or `path` to hit /up, /health, etc. The response includes the exact URL probed, status code, body preview, and (on failure) a per-stack diagnosis of likely causes."

  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "agent_id" => %{"type" => "string"},
        "port" => %{
          "type" => "integer",
          "description" =>
            "Container port to look up (e.g. 3000). Default: probe whatever's published on workspace or dev container."
        },
        "path" => %{
          "type" => "string",
          "description" =>
            "Request path. Default: '/'. Common alternatives: '/up' (Rails), '/health', '/healthz'."
        }
      },
      "required" => ["agent_id"]
    }
  end

  def execute(%{agent_id: agent_id} = params, _assigns) do
    container_port = Map.get(params, :port)
    path = Map.get(params, :path, "/")

    with {:ok, workspace_id} <- Helpers.agent_workspace_id(agent_id) do
      project_name = BoomLooper.Compose.project_name(workspace_id)
      candidates = discover_dev_host_ports(project_name, container_port)

      case try_probe_candidates(candidates, path, project_name) do
        {:ok, host_port, status, body, container_name} ->
          {:ok, format_probe_success(host_port, container_name, path, status, body)}

        {:error, :no_ports} ->
          {:ok, format_probe_no_ports(project_name)}

        {:error, {:no_response, attempted, container_states}} ->
          {:ok, format_probe_no_response(attempted, path, container_states)}
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

          :error ->
            {:cont, {[{container, container_port, host_port} | acc], nil}}
        end
      end)

    case results do
      {:found, host_port, container, status, body} ->
        {:ok, host_port, status, body, container}

      attempted when is_list(attempted) ->
        states =
          for {container, _, _} <- Enum.uniq_by(attempted, fn {c, _, _} -> c end), into: %{} do
            {container, container_running?(container)}
          end

        _ = project_name
        {:error, {:no_response, Enum.reverse(attempted), states}}
    end
  end

  defp container_running?(name), do: Docker.container_running?(name)

  defp http_get(url) do
    :inets.start()
    :ssl.start()

    case :httpc.request(:get, {String.to_charlist(url), []},
           [timeout: 5_000, connect_timeout: 3_000],
           body_format: :binary
         ) do
      {:ok, {{_, status, _}, _headers, body}} ->
        {:ok, status, String.slice(to_string(body), 0..600)}

      _ ->
        :error
    end
  end

  defp format_probe_success(host_port, container, path, status, body) do
    """
    HTTP #{status} from http://localhost:#{host_port}#{path}
    Mapped from container: #{container}

    Body preview:
    #{body}
    """
  end

  defp format_probe_no_ports(project_name) do
    """
    No host-mapped ports found for #{project_name}-workspace-1 or #{project_name}-dev-1.

    Either the containers aren't running, or your `dev` service in
    docker-compose.yml has no `ports:` declaration. Add something like:

      dev:
        ports:
          - "3000"

    Then `docker_compose("up -d --build")`.
    """
  end

  defp format_probe_no_response(attempted, path, container_states) do
    state_lines =
      container_states
      |> Enum.map(fn {name, running?} ->
        "  #{name}: #{if running?, do: "running", else: "NOT RUNNING"}"
      end)
      |> Enum.join("\n")

    attempted_urls =
      attempted
      |> Enum.map(fn {container, container_port, host_port} ->
        "  http://localhost:#{host_port}#{path}  (mapped from #{container}:#{container_port})"
      end)
      |> Enum.join("\n")

    """
    Connection refused on every host port I tried.

    URLs probed (in order):
    #{attempted_urls}

    Container states:
    #{state_lines}

    Likely causes:
    - Your dev server is bound to 127.0.0.1 inside the container (Rails default,
      Vite default, Flask default). Bind to 0.0.0.0:
        Rails:    `bin/rails server -b 0.0.0.0` or set BINDING=0.0.0.0
        Vite:     `--host 0.0.0.0` or `server.host = true`
        Flask:    `flask run --host=0.0.0.0`
        Django:   `python manage.py runserver 0.0.0.0:8000`
        Next.js:  binds to 0.0.0.0 by default — should be fine
    - Dev server is still booting. Check `logs service="dev"` and wait, then retry.
    - Wrong port: run `inspect_service name="dev"` to see what's actually listening.
    """
  end
end
