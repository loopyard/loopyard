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

  defstruct [:project_dir, :workspace_id, services: %{}, processes: [], workspace_container_running: false, rebuilding: false]

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
  def handle_call(:start_services, _from, %{rebuilding: true} = state) do
    {:reply, {:error, "A rebuild is in progress. Wait for it to finish."}, state}
  end

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

    new_state = %{state | workspace_container_running: false}
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
    state = %{state | rebuilding: true}

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
        new_state = %{state | processes: workspace.processes, workspace_container_running: ws_running, rebuilding: false}
        broadcast_service_update(new_state)
        {:reply, :ok, new_state}

      _ ->
        {:reply, :ok, %{state | rebuilding: false}}
    end
  end

  @impl true
  def handle_cast(:broadcast_status, state) do
    broadcast_service_update(state)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    require Logger

    # Clean up all Docker containers for this branch
    Enum.each(state.processes, fn p ->
      container = process_container_name(state.workspace_id, p.name)
      case Docker.docker(["rm", "-f", container]) do
        {:ok, _} -> :ok
        {:error, reason} -> Logger.warning("[ServiceManager] Failed to remove #{container}: #{reason}")
      end
    end)

    Enum.each(state.services, fn {name, _} ->
      container = service_container_name(state.workspace_id, name)
      case Docker.docker(["rm", "-f", container]) do
        {:ok, _} -> :ok
        {:error, reason} -> Logger.warning("[ServiceManager] Failed to remove #{container}: #{reason}")
      end
    end)

    case Docker.stop_workspace_container(state.workspace_id) do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.warning("[ServiceManager] Failed to stop workspace container: #{reason}")
    end

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

  # Ops container — always running, agents exec here. Idempotent.
  defp start_ops_container(state, workspace) do
    if Docker.workspace_container_running?(state.workspace_id) do
      true
    else
      case Docker.start_workspace_container(state.workspace_id,
        bind_mount: state.project_dir,
        env_vars: workspace.env_vars || %{}
      ) do
        {:ok, _} -> true
        {:error, _} -> false
      end
    end
  end

  # Process containers — one per process, run from workspace image
  defp start_process_containers(_state, %{processes: []}), do: true
  defp start_process_containers(state, workspace) do
    image = Docker.workspace_image_name(state.workspace_id)

    Enum.all?(workspace.processes, fn p ->
      container = process_container_name(state.workspace_id, p.name)

      # Skip if already running
      if Docker.container_running?(container) do
        true
      else
      Docker.docker(["rm", "-f", container])

      args = [
        "run", "-d",
        "--name", container,
        "--network", Docker.network_name(),
        "--mount", "type=bind,src=#{state.project_dir},dst=/workspace",
        "-w", "/workspace"
      ] ++ dynamic_port_args(p[:ports]) ++ env_args(workspace.env_vars) ++ [image, "sh", "-c", p.command]

      match?({:ok, _}, Docker.docker(args, timeout: 30_000))
      end
    end)
  end

  defp start_stock_service_container(state, service) do
    container = service_container_name(state.workspace_id, service.name)

    # Skip if already running
    if Docker.container_running?(container) do
      {:ok, :already_running}
    else
    Docker.docker(["rm", "-f", container])
    Docker.ensure_network()

    vol_name = service_volume_name(state.workspace_id, service.name)
    Docker.docker(["volume", "create", vol_name])

    # Auto-mount data volume for known service types + any custom volumes
    auto_volume = auto_data_volume(service[:image], vol_name)
    custom_volumes = Enum.flat_map(service[:volumes] || [], fn spec -> ["-v", "#{spec}"] end)
    volume_args = auto_volume ++ custom_volumes

    args =
      ["run", "-d", "--name", container, "--network", Docker.network_name()] ++
        env_args(service[:env]) ++ dynamic_port_args(service[:ports]) ++ volume_args ++ [service.image]

    case Docker.docker(args, timeout: 120_000) do
      {:ok, _} -> {:ok, :started}
      {:error, reason} -> {:error, "Failed to start #{service.name}: #{reason}"}
    end
    end
  end

  defp via(project_dir) do
    {:via, Registry, {BoomLooper.ServiceManagerRegistry, project_dir}}
  end

  defp build_stock_statuses(state) do
    Enum.map(state.services, fn {name, service} ->
      container = service_container_name(state.workspace_id, name)
      running = Docker.container_running?(container)
      # Get actual host ports (dynamic allocation)
      ports = if running, do: Docker.container_ports(container), else: %{}

      %{
        name: name,
        image: service[:image],
        type: :stock,
        running: running,
        container: container,
        ports: ports
      }
    end)
  end

  defp build_process_statuses(state) do
    Enum.map(state.processes, fn p ->
      container = process_container_name(state.workspace_id, p.name)
      running = Docker.container_running?(container)
      ports = if running, do: Docker.container_ports(container), else: %{}
      # Include exit info when not running so the UI can show WHY it died
      exit_info = if !running, do: Docker.container_state(container), else: nil

      %{
        name: p.name,
        command: p.command,
        type: :process,
        running: running,
        container: container,
        ports: ports,
        exit_info: exit_info
      }
    end)
  end

  defp build_workspace_status(state) do
    ws_container = Docker.workspace_container_name(state.workspace_id)
    # Always check Docker directly — don't trust cached state
    running = Docker.container_running?(ws_container)

    if state.workspace_container_running || running do
      [%{
        name: "workspace",
        type: :workspace,
        running: running,
        container: ws_container,
        ports: %{}
      }]
    else
      []
    end
  end

  # Auto-detect data volume mount path for known service images
  defp auto_data_volume(image, vol_name) when is_binary(image) do
    cond do
      String.contains?(image, "postgres") -> ["-v", "#{vol_name}:/var/lib/postgresql/data"]
      String.contains?(image, "redis") -> ["-v", "#{vol_name}:/data"]
      String.contains?(image, "mysql") || String.contains?(image, "mariadb") -> ["-v", "#{vol_name}:/var/lib/mysql"]
      String.contains?(image, "mongo") -> ["-v", "#{vol_name}:/data/db"]
      String.contains?(image, "elasticsearch") || String.contains?(image, "opensearch") -> ["-v", "#{vol_name}:/usr/share/elasticsearch/data"]
      true -> []
    end
  end

  defp auto_data_volume(_, _), do: []

  # Build -p args with dynamic host ports (0:container_port)
  defp dynamic_port_args(ports) when is_list(ports) do
    Enum.flat_map(ports, fn ps ->
      container_port = ps |> String.split(":") |> List.last()
      ["-p", "0:#{container_port}"]
    end)
  end

  defp dynamic_port_args(ports) when is_map(ports) do
    Enum.flat_map(ports, fn {_h, c} -> ["-p", "0:#{c}"] end)
  end

  defp dynamic_port_args(_), do: []

  defp env_args(env_vars) do
    Enum.flat_map(env_vars || %{}, fn {k, v} -> ["-e", "#{k}=#{v}"] end)
  end

  defp broadcast_service_update(state) do
    all_statuses = build_workspace_status(state) ++ build_process_statuses(state) ++ build_stock_statuses(state)

    Phoenix.PubSub.broadcast(
      BoomLooper.PubSub,
      @services_topic,
      {:services_updated, state.project_dir, all_statuses}
    )
  end
end
