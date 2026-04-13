defmodule BoomLooper.Tools.Container.FileUrl do
  use BoomLooper.Tool,
    name: "file_url",
    description: "Get clickable URLs for the user. Two modes: (1) 'file' mode returns a URL to view a workspace file with syntax highlighting. (2) 'app' mode returns a URL to the running dev server at a specific path — use this when the user wants to see a page, feature, or route in their browser. The tool figures out the correct host port mapping automatically.",
    params: [
      agent_id: {:string, required: true},
      path: {:string, required: true, description: "For 'file' mode: file path relative to /workspace (e.g. 'Gemfile'). For 'app' mode: the route path (e.g. '/users', '/admin/dashboard')"},
      mode: {:string, description: "Either 'file' (default) or 'app'. Use 'app' when the user wants to see a running page."}
    ]

  alias BoomLooper.Tools.Container.Helpers

  def execute(%{agent_id: agent_id, path: path} = params, _assigns) do
    mode = Map.get(params, :mode, "file")

    case mode do
      "app" -> app_url(agent_id, path)
      _ -> file_url(agent_id, path)
    end
  end

  # Returns a URL to the running dev server at the given route path
  defp app_url(agent_id, route_path) do
    case BoomLooper.ChatAgent.get_state(agent_id) do
      %{workspace_id: workspace_id} when is_binary(workspace_id) ->
        # Find the dev container's host port
        project_name = BoomLooper.Compose.project_name(workspace_id)
        dev_container = "#{project_name}-dev-1"

        case BoomLooper.Docker.container_ports(dev_container) do
          {:ok, ports} when map_size(ports) > 0 ->
            # Pick the first mapped port (usually the web server)
            {_container_port, host_port} = Enum.at(ports, 0)
            clean_route = if String.starts_with?(route_path, "/"), do: route_path, else: "/#{route_path}"
            {:ok, "http://localhost:#{host_port}#{clean_route}"}

          _ ->
            # Try getting ports from Observer
            containers = BoomLooper.Docker.Observer.containers_for(workspace_id)
            dev = Enum.find(containers, &(&1.name == dev_container))

            case dev && dev[:host_ports] do
              ports when is_map(ports) and map_size(ports) > 0 ->
                {_container_port, host_port} = Enum.at(ports, 0)
                clean_route = if String.starts_with?(route_path, "/"), do: route_path, else: "/#{route_path}"
                {:ok, "http://localhost:#{host_port}#{clean_route}"}

              _ ->
                {:error, "Dev container (#{dev_container}) has no mapped ports. Is it running? Check with service_containers."}
            end
        end

      _ ->
        {:error, "Agent #{agent_id} has no workspace"}
    end
  end

  # Returns a URL to view a file in BoomLooper's file viewer
  defp file_url(agent_id, path) do
    case BoomLooper.ChatAgent.get_state(agent_id) do
      %{workspace_id: workspace_id} when is_binary(workspace_id) ->
        volume_name = BoomLooper.Workspace.volume_name_for(workspace_id)
        workspace = BoomLooper.ProjectRegistry.get_workspace(workspace_id)
        project_id = workspace && workspace[:project_id]

        if project_id do
          clean_path = clean_file_path(path)
          base = boomlooper_base_url()

          view_url = "#{base}/projects/#{project_id}/workspaces/#{workspace_id}/volumes/#{volume_name}/files/#{clean_path}"
          raw_url = "#{base}/raw/#{volume_name}/#{clean_path}"

          {:ok, "View: #{view_url}\nRaw: #{raw_url}"}
        else
          {:error, "Could not determine project for workspace #{workspace_id}"}
        end

      _ ->
        {:error, "Agent #{agent_id} has no workspace"}
    end
  end

  defp clean_file_path(path) do
    path
    |> String.trim_leading("/")
    |> String.trim_leading("./")
    |> String.trim_leading("workspace/")
  end

  defp boomlooper_base_url do
    endpoint = BoomLooperWeb.Endpoint

    case endpoint.config(:url) do
      config when is_list(config) ->
        scheme = Keyword.get(config, :scheme, "http")
        host = Keyword.get(config, :host, "localhost")
        port = Keyword.get(config, :port)

        if port && port not in [80, 443] do
          "#{scheme}://#{host}:#{port}"
        else
          "#{scheme}://#{host}"
        end

      _ ->
        port = endpoint.config(:http)[:port] || 4000
        "http://localhost:#{port}"
    end
  end
end
