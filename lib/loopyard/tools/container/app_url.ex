defmodule Loopyard.Tools.Container.AppUrl do
  use Loopyard.Tool,
    name: "app_url",
    description:
      "THE source of the app's OUTSIDE address — the one a human can open. Call it " <>
        "after building a feature or fixing a bug, and any time you're about to hand " <>
        "over a link. Returns the URL on the first line (paste that verbatim), then " <>
        "the INSIDE address to use for your own curls/health checks. Never construct " <>
        "the outside address yourself from a port mapping or a remembered value: it " <>
        "may be a LAN address or a tunnel hostname, and it can change between calls.",
    busy_words: ["building a link", "URL crafting"],
    params: [
      agent_id: {:string, required: true},
      path:
        {:string,
         required: true,
         description:
           "Route path in the app (e.g. '/', '/users', '/admin/dashboard', '/code/my-article')"},
      service:
        {:string, description: "Compose service name to get the port from (default: 'dev')"}
    ]

  @doc """
  The app's two addresses, in one call — so the agent never has to derive either.

  Line 1 is the OUTSIDE address (what a human opens); everything after is a note
  carrying the INSIDE address (`localhost:<container_port>`) for the agent's own
  curls. Agents kept conflating the two — reading a port mapping and handing the
  user a container port, or curling the host port from inside the container —
  which burns a turn debugging the wrong layer.

  Today the outside address is `http://localhost:<host_port>`, and the UI's
  markdown renderer rewrites `localhost` to the viewer's hostname
  (window.location.hostname) so the link works from any machine. When the
  outside address becomes something else entirely — a `*.loopyard.ai` relay —
  it changes HERE and nowhere else: no prompt edits, no agent relearning,
  because nothing downstream is allowed to build the URL itself.
  """
  def execute(%{agent_id: agent_id, path: route_path} = params, _assigns) do
    service = Map.get(params, :service, "dev")

    case Loopyard.ChatAgent.get_state(agent_id) do
      %{workspace_id: workspace_id} when is_binary(workspace_id) ->
        project_name = Loopyard.Compose.project_name(workspace_id)
        container = "#{project_name}-#{service}-1"

        case find_host_port(workspace_id, service, container) do
          {:ok, host_port, exposed?, cport} ->
            clean_path =
              if String.starts_with?(route_path, "/"), do: route_path, else: "/#{route_path}"

            url =
              %URI{scheme: "http", host: "localhost", port: host_port, path: clean_path}
              |> URI.to_string()

            # Line 1 is always the pasteable outside URL; notes go below it so a
            # careless paste still hands over a working link.
            inside =
              if cport,
                do: "\n\n> For your OWN testing inside the container, use `localhost:#{cport}`.",
                else: ""

            if exposed? do
              {:ok, url <> inside}
            else
              {:ok,
               "#{url}\n\n> **This port is local-only.** To access from another device, open port #{service}/#{cport}." <>
                 inside}
            end

          :no_ports ->
            {:error,
             "#{container} has no mapped ports. Is it running? Try `service_containers` to check."}
        end

      _ ->
        {:error, "Agent #{agent_id} has no workspace"}
    end
  end

  # Prefer the registry — it has the assignment even when the
  # container is momentarily stopped or restarting. Fall through to
  # Docker for legacy workspaces or services that somehow ended up
  # container-bound without a registry entry.
  defp find_host_port(workspace_id, service, container) do
    case registry_host_port(workspace_id, service) do
      {:ok, _, _, _} = ok ->
        ok

      :none ->
        case docker_host_port(workspace_id, container) do
          {:ok, port} -> {:ok, port, false, nil}
          :no_ports -> :no_ports
        end
    end
  end

  defp registry_host_port(workspace_id, service) do
    entries = Loopyard.PortRegistry.list_for_workspace(workspace_id)

    case Enum.find(entries, &(&1.service == service)) do
      %{host_port: hp, exposed: exposed, container_port: cp} -> {:ok, hp, exposed, cp}
      %{host_port: hp, container_port: cp} -> {:ok, hp, false, cp}
      nil -> :none
    end
  end

  defp docker_host_port(workspace_id, container) do
    case Loopyard.Docker.container_ports(container) do
      ports when is_map(ports) and map_size(ports) > 0 ->
        {_container_port, host_port} = Enum.at(ports, 0)
        {:ok, host_port}

      _ ->
        containers = Loopyard.Docker.Observer.containers_for(workspace_id)
        dev = Enum.find(containers, &(&1.name == container))

        case dev && dev[:host_ports] do
          ports when is_map(ports) and map_size(ports) > 0 ->
            {_cp, hp} = Enum.at(ports, 0)
            {:ok, hp}

          _ ->
            :no_ports
        end
    end
  end
end
