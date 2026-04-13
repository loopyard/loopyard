defmodule BoomLooper.Tools.Container.AppUrl do
  use BoomLooper.Tool,
    name: "app_url",
    description: "Get a clickable URL to a page in the running dev server. Use this after building a feature, fixing a bug, or when the user asks to see/open/view something in their browser. The URL uses the correct Docker host port and the user's actual connection hostname (LAN IP, tunnel, etc.).",
    params: [
      agent_id: {:string, required: true},
      path: {:string, required: true, description: "Route path in the app (e.g. '/', '/users', '/admin/dashboard', '/code/my-article')"},
      service: {:string, description: "Compose service name to get the port from (default: 'dev')"}
    ]

  def execute(%{agent_id: agent_id, path: route_path} = params, _assigns) do
    service = Map.get(params, :service, "dev")

    case BoomLooper.ChatAgent.get_state(agent_id) do
      %{workspace_id: workspace_id} = state when is_binary(workspace_id) ->
        project_name = BoomLooper.Compose.project_name(workspace_id)
        container = "#{project_name}-#{service}-1"

        case find_host_port(workspace_id, container) do
          {:ok, host_port} ->
            base_uri = parse_base_url(state[:base_url])
            clean_path = if String.starts_with?(route_path, "/"), do: route_path, else: "/#{route_path}"

            url =
              %URI{base_uri | port: String.to_integer("#{host_port}"), path: clean_path}
              |> URI.to_string()

            {:ok, url}

          :no_ports ->
            {:error, "#{container} has no mapped ports. Is it running? Try `service_containers` to check."}
        end

      _ ->
        {:error, "Agent #{agent_id} has no workspace"}
    end
  end

  @doc false
  def parse_base_url(nil), do: %URI{scheme: "http", host: "localhost", port: 80}
  def parse_base_url(base_url) do
    case URI.parse(base_url) do
      %URI{host: host} = uri when is_binary(host) and host != "" ->
        %URI{uri | scheme: uri.scheme || "http"}
      _ ->
        %URI{scheme: "http", host: "localhost", port: 80}
    end
  end

  defp find_host_port(workspace_id, container) do
    case BoomLooper.Docker.container_ports(container) do
      {:ok, ports} when map_size(ports) > 0 ->
        {_container_port, host_port} = Enum.at(ports, 0)
        {:ok, host_port}

      _ ->
        containers = BoomLooper.Docker.Observer.containers_for(workspace_id)
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
