defmodule BoomLooper.Workspace.ServiceManager do
  @moduledoc """
  GenServer managing all containers for a workspace.

  Each workspace has:
  - **ops container** — always running `sleep infinity`, agents exec into this one
  - **process containers** — one per workspace process (web, css, etc.), run from the workspace image
  - **stock service containers** — postgres, redis, etc., run from their own images

  All containers share the Docker network and workspace bind mount.

  Container naming:
  - ops:      boom-looper-ws-{workspace_id}
  - process:  boom-looper-ws-{workspace_id}-{process_name}
  - stock:    boom-looper-svc-{workspace_id}-{service_name}
  """
  use GenServer, restart: :transient

  alias BoomLooper.Docker

  @prefix "boom-looper-svc"
  @services_topic "workspace_services"

  defstruct [:project_dir, :workspace_id, services: %{}, processes: [], workspace_container_running: false]

  # --- Public API ---

  def start_link(opts) do
    project_dir = Keyword.fetch!(opts, :project_dir)
    GenServer.start_link(__MODULE__, opts, name: via(project_dir))
  end

  @doc "Start all services defined in the workspace config"
  def start_services(project_dir) do
    case Registry.lookup(BoomLooper.ServiceManagerRegistry, project_dir) do
      [{pid, _}] -> GenServer.call(pid, :start_services, 120_000)
      [] -> {:error, :service_manager_not_running}
    end
  end

  @doc "Stop all service containers for a workspace"
  def stop_services(project_dir) do
    case Registry.lookup(BoomLooper.ServiceManagerRegistry, project_dir) do
      [{pid, _}] -> GenServer.call(pid, :stop_services, 30_000)
      [] -> :ok
    end
  end

  @doc "Execute a command in a service container"
  def service_exec(project_dir, service_name, command) do
    workspace_id = BoomLooper.Workspace.workspace_id(project_dir)
    container = service_container_name(workspace_id, service_name)

    case Docker.docker(["exec", "-i", container, "sh", "-c", command], timeout: 120_000) do
      {:ok, output} -> {:ok, output}
      {:error, reason} -> {:error, "Failed to exec in #{service_name}: #{reason}"}
    end
  end

  @doc "Get status of all services for a workspace"
  def service_status(project_dir) do
    case Registry.lookup(BoomLooper.ServiceManagerRegistry, project_dir) do
      [{pid, _}] -> GenServer.call(pid, :service_status)
      [] -> {:ok, []}
    end
  end

  @doc "Restart the workspace container and all process containers after an image rebuild"
  def restart_workspace_container(project_dir) do
    case Registry.lookup(BoomLooper.ServiceManagerRegistry, project_dir) do
      [{pid, _}] -> GenServer.call(pid, :restart_workspace_container, 120_000)
      [] -> :ok
    end
  end

  @doc "Subscribe to service status updates"
  def subscribe do
    Phoenix.PubSub.subscribe(BoomLooper.PubSub, @services_topic)
  end

  @doc "Container name for a stock service"
  def service_container_name(workspace_id, service_name) do
    "#{@prefix}-#{workspace_id}-#{service_name}"
  end

  @doc "Container name for a workspace process"
  def process_container_name(workspace_id, process_name) do
    "#{Docker.workspace_container_name(workspace_id)}-#{process_name}"
  end

  @doc "Data volume name for a workspace service"
  def service_volume_name(workspace_id, service_name) do
    "#{@prefix}-#{workspace_id}-#{service_name}-data"
  end

  # --- Callbacks ---

  @impl true
  def init(opts) do
    project_dir = Keyword.fetch!(opts, :project_dir)
    workspace_id = BoomLooper.Workspace.workspace_id(project_dir)
    {:ok, %__MODULE__{project_dir: project_dir, workspace_id: workspace_id}}
  end

  @impl true
  def handle_call(:start_services, _from, state) do
    case BoomLooper.Workspace.load(state.project_dir) do
      {:ok, workspace} ->
        has_workspace = workspace.processes != [] || workspace.dockerfile != nil
        ws_running =
          if has_workspace do
            ensure_workspace_image(state.workspace_id, workspace)
            start_ops_container(state, workspace) && start_process_containers(state, workspace)
          else
            false
          end

        stock_results = Enum.map(workspace.services, &start_stock_service_container(state, &1))

        services = Map.new(workspace.services, fn s -> {s.name, s} end)
        new_state = %{state |
          services: services,
          processes: workspace.processes,
          workspace_container_running: ws_running
        }
        broadcast_service_update(new_state)
        {:reply, {:ok, stock_results}, new_state}

      :none ->
        {:reply, {:ok, []}, state}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  @impl true
  def handle_call(:stop_services, _from, state) do
    # Stop stock service containers
    Enum.each(state.services, fn {name, _} ->
      Docker.docker(["rm", "-f", service_container_name(state.workspace_id, name)])
    end)

    # Stop process containers
    Enum.each(state.processes, fn p ->
      Docker.docker(["rm", "-f", process_container_name(state.workspace_id, p.name)])
    end)

    # Stop ops container
    Docker.stop_workspace_container(state.workspace_id)

    new_state = %{state | services: %{}, processes: [], workspace_container_running: false}
    broadcast_service_update(new_state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:service_status, _from, state) do
    all_statuses = build_workspace_status(state) ++ build_process_statuses(state) ++ build_stock_statuses(state)
    {:reply, {:ok, all_statuses}, state}
  end

  @impl true
  def handle_call(:restart_workspace_container, _from, state) do
    # Stop process containers
    Enum.each(state.processes, fn p ->
      Docker.docker(["rm", "-f", process_container_name(state.workspace_id, p.name)])
    end)

    # Stop ops container
    Docker.stop_workspace_container(state.workspace_id)

    case BoomLooper.Workspace.load(state.project_dir) do
      {:ok, workspace} ->
        ensure_workspace_image(state.workspace_id, workspace)
        ws_running = start_ops_container(state, workspace) && start_process_containers(state, workspace)
        new_state = %{state | processes: workspace.processes, workspace_container_running: ws_running}
        broadcast_service_update(new_state)
        {:reply, :ok, new_state}

      _ ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    # Clean up all Docker containers for this branch
    Enum.each(state.processes, fn p ->
      Docker.docker(["rm", "-f", process_container_name(state.workspace_id, p.name)])
    end)

    Enum.each(state.services, fn {name, _} ->
      Docker.docker(["rm", "-f", service_container_name(state.workspace_id, name)])
    end)

    Docker.stop_workspace_container(state.workspace_id)
    :ok
  end

  # --- Private ---

  defp ensure_workspace_image(workspace_id, workspace) do
    if workspace.processes != [] || workspace.dockerfile != nil do
      dockerfile = workspace.dockerfile || Docker.dockerfile()
      Docker.build_workspace_image(workspace_id, dockerfile)
    else
      :ok
    end
  end

  # Ops container — always running, agents exec here
  defp start_ops_container(state, workspace) do
    case Docker.start_workspace_container(state.workspace_id,
      bind_mount: state.project_dir,
      env_vars: workspace.env_vars || %{}
    ) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  # Process containers — one per process, run from workspace image
  defp start_process_containers(_state, %{processes: []}), do: true
  defp start_process_containers(state, workspace) do
    image = Docker.workspace_image_name(state.workspace_id)

    Enum.all?(workspace.processes, fn p ->
      container = process_container_name(state.workspace_id, p.name)
      Docker.docker(["rm", "-f", container])

      port_args =
        case p[:ports] do
          ports when is_list(ports) -> Enum.flat_map(ports, fn ps -> ["-p", ps] end)
          ports when is_map(ports) -> Enum.flat_map(ports, fn {h, c} -> ["-p", "#{h}:#{c}"] end)
          _ -> []
        end

      env_args =
        Enum.flat_map(workspace.env_vars || %{}, fn {k, v} -> ["-e", "#{k}=#{v}"] end)

      args = [
        "run", "-d",
        "--name", container,
        "--network", Docker.network_name(),
        "--mount", "type=bind,src=#{state.project_dir},dst=/workspace",
        "-w", "/workspace"
      ] ++ port_args ++ env_args ++ [image, "sh", "-c", p.command]

      match?({:ok, _}, Docker.docker(args, timeout: 30_000))
    end)
  end

  defp start_stock_service_container(state, service) do
    container = service_container_name(state.workspace_id, service.name)

    Docker.docker(["rm", "-f", container])
    Docker.ensure_network()

    env_args = Enum.flat_map(service[:env] || %{}, fn {k, v} -> ["-e", "#{k}=#{v}"] end)
    port_args = Enum.flat_map(service[:ports] || [], fn
      {host, cp} -> ["-p", "#{host}:#{cp}"]
      port_str when is_binary(port_str) -> ["-p", port_str]
    end)

    vol_name = service_volume_name(state.workspace_id, service.name)
    Docker.docker(["volume", "create", vol_name])

    volume_args = Enum.flat_map(service[:volumes] || [], fn spec -> ["-v", "#{spec}"] end)

    args =
      ["run", "-d", "--name", container, "--network", Docker.network_name()] ++
        env_args ++ port_args ++ volume_args ++ [service.image]

    case Docker.docker(args, timeout: 120_000) do
      {:ok, _} -> {:ok, :started}
      {:error, reason} -> {:error, "Failed to start #{service.name}: #{reason}"}
    end
  end

  defp via(project_dir) do
    {:via, Registry, {BoomLooper.ServiceManagerRegistry, project_dir}}
  end

  defp build_stock_statuses(state) do
    Enum.map(state.services, fn {name, service} ->
      container = service_container_name(state.workspace_id, name)

      %{
        name: name,
        image: service[:image],
        type: :stock,
        running: Docker.container_running?(container),
        container: container,
        ports: service[:ports] || %{}
      }
    end)
  end

  defp build_process_statuses(state) do
    Enum.map(state.processes, fn p ->
      container = process_container_name(state.workspace_id, p.name)

      %{
        name: p.name,
        command: p.command,
        type: :process,
        running: Docker.container_running?(container),
        container: container,
        ports: normalize_ports(p[:ports])
      }
    end)
  end

  defp build_workspace_status(state) do
    ws_container = Docker.workspace_container_name(state.workspace_id)

    if state.workspace_container_running do
      [%{
        name: "workspace",
        type: :workspace,
        running: Docker.container_running?(ws_container),
        container: ws_container,
        ports: %{}
      }]
    else
      []
    end
  end

  defp normalize_ports(ports) when is_list(ports) do
    Enum.into(ports, %{}, fn port_str ->
      case String.split(port_str, ":") do
        [h, c] -> {h, c}
        [p] -> {p, p}
      end
    end)
  end

  defp normalize_ports(ports) when is_map(ports), do: ports
  defp normalize_ports(_), do: %{}

  defp broadcast_service_update(state) do
    all_statuses = build_workspace_status(state) ++ build_process_statuses(state) ++ build_stock_statuses(state)

    Phoenix.PubSub.broadcast(
      BoomLooper.PubSub,
      @services_topic,
      {:services_updated, state.project_dir, all_statuses}
    )
  end
end
