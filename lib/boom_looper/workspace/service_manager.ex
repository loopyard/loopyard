defmodule BoomLooper.Workspace.ServiceManager do
  @moduledoc """
  GenServer managing Docker Compose services for a workspace.

  Generates docker-compose.yml from workspace config, runs
  `docker compose up/down`, monitors health via TCP port checks.

  Container naming and networking handled by compose.
  """
  use GenServer, restart: :transient

  alias BoomLooper.{Compose, Docker, Workspace}

  @services_topic "workspace_services"

  defstruct [
    :project_dir,
    :workspace_id,
    services: %{},
    processes: [],
    running: false,
    rebuilding: false,
    service_health: %{}
  ]

  # --- Public API ---

  def start_link(opts) do
    project_dir = Keyword.fetch!(opts, :project_dir)
    GenServer.start_link(__MODULE__, opts, name: via(project_dir))
  end

  def start_services(project_dir) do
    case Registry.lookup(BoomLooper.ServiceManagerRegistry, project_dir) do
      [{pid, _}] -> GenServer.call(pid, :start_services, 600_000)
      [] -> {:error, :service_manager_not_running}
    end
  end

  def stop_services(project_dir) do
    case Registry.lookup(BoomLooper.ServiceManagerRegistry, project_dir) do
      [{pid, _}] -> GenServer.call(pid, :stop_services, 30_000)
      [] -> :ok
    end
  end

  def service_status(project_dir) do
    case Registry.lookup(BoomLooper.ServiceManagerRegistry, project_dir) do
      [{pid, _}] -> GenServer.call(pid, :service_status)
      [] -> {:ok, []}
    end
  end

  def restart_workspace_container(project_dir) do
    case Registry.lookup(BoomLooper.ServiceManagerRegistry, project_dir) do
      [{pid, _}] -> GenServer.call(pid, :restart, 600_000)
      [] -> :ok
    end
  end

  def service_exec(project_dir, service_name, command) do
    workspace_id = Workspace.workspace_id(project_dir)
    Compose.exec(project_dir, workspace_id, service_name, command)
  end

  def subscribe do
    Phoenix.PubSub.subscribe(BoomLooper.PubSub, @services_topic)
  end

  @doc "Container name for a compose service"
  def service_container_name(workspace_id, service_name) do
    # Compose naming: {project}_{service}_{n}
    "#{Compose.project_name(workspace_id)}-#{service_name}-1"
  end

  @doc "Alias for process containers (same naming in compose)"
  def process_container_name(workspace_id, process_name) do
    service_container_name(workspace_id, process_name)
  end

  def service_volume_name(workspace_id, service_name) do
    "#{service_name}-data-#{workspace_id}"
  end

  # --- Callbacks ---

  @impl true
  def init(opts) do
    project_dir = Keyword.fetch!(opts, :project_dir)
    workspace_id = Workspace.workspace_id(project_dir)
    state = %__MODULE__{project_dir: project_dir, workspace_id: workspace_id}

    # Check if compose containers are already running (survived a server reboot)
    case Workspace.load(project_dir) do
      {:ok, ws} when ws.dockerfile != nil ->
        self_pid = self()
        Task.start(fn ->
          case Compose.ps(project_dir, workspace_id) do
            {:ok, running} when running != [] ->
              # Containers already running — reconnect state without rebuilding
              GenServer.call(self_pid, {:reconnect, ws}, 30_000)

            _ ->
              # No running containers — do a full start
              GenServer.call(self_pid, :start_services, 600_000)
          end
        end)
      _ -> :ok
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:start_services, _from, %{rebuilding: true} = state) do
    {:reply, {:error, "A rebuild is in progress."}, state}
  end

  def handle_call(:start_services, _from, state) do
    # Don't restart if already running
    if state.running do
      {:reply, {:ok, []}, state}
    else
      case do_start(state) do
        {:ok, new_state} -> {:reply, {:ok, []}, new_state}
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    end
  end

  @impl true
  def handle_call({:reconnect, ws}, _from, state) do
    BoomLooper.EventLog.info("workspace:#{state.workspace_id}", "Reconnecting to existing compose containers")

    # Replay agent log to restore agent state to ETS and start agents
    replay_agent_log(state.project_dir, state.workspace_id)

    services = Map.new(ws.services, fn s -> {s.name, s} end)
    all_names = Enum.map(ws.processes, & &1.name) ++ Enum.map(ws.services, & &1.name) ++ ["workspace"]
    initial_health = Map.new(all_names, fn name -> {name, :started} end)

    new_state = %{state |
      services: services,
      processes: ws.processes,
      running: true,
      service_health: initial_health
    }
    broadcast_service_update(new_state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:stop_services, _from, state) do
    do_stop(state)
    new_state = %{state | running: false, service_health: %{}}
    broadcast_service_update(new_state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:service_status, _from, state) do
    statuses = build_statuses(state)
    {:reply, {:ok, statuses}, state}
  end

  @impl true
  def handle_call(:restart, _from, state) do
    state = %{state | rebuilding: true}
    do_stop(state)

    case do_start(state) do
      {:ok, new_state} ->
        {:reply, :ok, %{new_state | rebuilding: false}}
      {:error, reason} ->
        {:reply, {:error, reason}, %{state | rebuilding: false, running: false}}
    end
  end

  @impl true
  def handle_cast(:broadcast_status, state) do
    broadcast_service_update(state)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:check_health, state) do
    health = update_health(state)
    new_state = %{state | service_health: health}
    if health != state.service_health, do: broadcast_service_update(new_state)
    {:noreply, new_state}
  end

  @impl true
  def terminate(_reason, state) do
    # Intentionally do NOT call compose down here.
    # Containers should survive server reboots. Use /system/reset for intentional teardown.
    BoomLooper.EventLog.info("workspace:#{state.workspace_id}", "ServiceManager stopping (containers kept running)")
    :ok
  end

  # --- Private ---

  defp do_start(state) do
    case Workspace.load(state.project_dir) do
      {:ok, ws} ->
        # Generate compose file
        case Compose.write(state.project_dir, state.workspace_id) do
          {:ok, _path} ->
            BoomLooper.EventLog.info("workspace:#{state.workspace_id}", "Starting compose services")

            case Compose.up(state.project_dir, state.workspace_id) do
              {:ok, _} ->
                # Replay agent log to restore any persisted agents
                replay_agent_log(state.project_dir, state.workspace_id)

                services = Map.new(ws.services, fn s -> {s.name, s} end)
                all_names = Enum.map(ws.processes, & &1.name) ++ Enum.map(ws.services, & &1.name) ++ ["workspace"]
                initial_health = Map.new(all_names, fn name -> {name, :started} end)

                new_state = %{state |
                  services: services,
                  processes: ws.processes,
                  running: true,
                  service_health: initial_health
                }
                broadcast_service_update(new_state)
                {:ok, new_state}

              {:error, reason} ->
                BoomLooper.EventLog.error("workspace:#{state.workspace_id}", "Compose up failed: #{reason}")
                {:error, reason}
            end

          other ->
            {:error, "Failed to write compose file: #{inspect(other)}"}
        end

      :none ->
        {:ok, state}

      {:error, _} = err ->
        err
    end
  end

  defp do_stop(state) do
    case Compose.down(state.project_dir, state.workspace_id) do
      {:ok, _} -> :ok
      {:error, reason} ->
        require Logger
        Logger.warning("[ServiceManager] compose down failed: #{reason}")
    end
  end

  defp build_statuses(state) do
    workspace_status = build_workspace_status(state)
    process_statuses = build_process_statuses(state)
    stock_statuses = build_stock_statuses(state)
    workspace_status ++ process_statuses ++ stock_statuses
  end

  defp build_workspace_status(state) do
    container = service_container_name(state.workspace_id, "workspace")
    running = Docker.container_running?(container)
    health = Map.get(state.service_health, "workspace", :stopped)

    if state.running || running do
      [%{name: "workspace", type: :workspace, running: running, container: container, ports: %{}, health: health}]
    else
      []
    end
  end

  defp build_process_statuses(state) do
    Enum.map(state.processes, fn p ->
      container = service_container_name(state.workspace_id, p.name)
      running = Docker.container_running?(container)
      ports = if running, do: Docker.container_ports(container), else: %{}
      exit_info = if !running, do: Docker.container_state(container), else: nil
      health = Map.get(state.service_health, p.name, :stopped)

      %{
        name: p.name,
        command: p.command,
        type: :process,
        running: running,
        container: container,
        ports: ports,
        exit_info: exit_info,
        health: health
      }
    end)
  end

  defp build_stock_statuses(state) do
    Enum.map(state.services, fn {name, service} ->
      container = service_container_name(state.workspace_id, name)
      running = Docker.container_running?(container)
      ports = if running, do: Docker.container_ports(container), else: %{}
      exit_info = if !running, do: Docker.container_state(container), else: nil
      health = Map.get(state.service_health, name, :stopped)

      %{
        name: name,
        image: service[:image],
        type: :stock,
        running: running,
        container: container,
        ports: ports,
        exit_info: exit_info,
        health: health
      }
    end)
  end

  defp update_health(state) do
    all_services =
      [{"workspace", service_container_name(state.workspace_id, "workspace")}] ++
      Enum.map(state.processes, fn p ->
        {p.name, service_container_name(state.workspace_id, p.name)}
      end) ++
      Enum.map(state.services, fn {name, _} ->
        {name, service_container_name(state.workspace_id, name)}
      end)

    Map.new(all_services, fn {name, container} ->
      current = Map.get(state.service_health, name, :stopped)
      running = Docker.container_running?(container)

      new_health = cond do
        !running ->
          exit_info = Docker.container_state(container)
          if exit_info && exit_info.exit_code > 0, do: :crashed, else: :stopped

        current == :healthy ->
          :healthy

        running ->
          ports = Docker.container_ports(container)
          if ports == %{} do
            :healthy  # No ports = healthy when running (workspace container)
          else
            {_cp, host_port} = Enum.at(ports, 0)
            if Docker.port_open?(host_port), do: :healthy, else: :started
          end
      end

      {name, new_health}
    end)
  end

  defp broadcast_service_update(state) do
    all_statuses = build_statuses(state)

    Phoenix.PubSub.broadcast(
      BoomLooper.PubSub,
      @services_topic,
      {:services_updated, state.project_dir, all_statuses}
    )
  end

  defp via(project_dir) do
    {:via, Registry, {BoomLooper.ServiceManagerRegistry, project_dir}}
  end

  defp replay_agent_log(project_dir, workspace_id) do
    log_path = Path.join([project_dir, ".boomlooper", "workspace", "agents.log"])

    case BoomLooper.AgentLog.replay(log_path: log_path, ets_table: :chat_agents) do
      {:ok, agents} when map_size(agents) > 0 ->
        BoomLooper.EventLog.info("workspace", "Restored #{map_size(agents)} agent(s) from log, starting...")

        # Start each agent with resume: true
        for {agent_id, _agent_data} <- agents do
          start_restored_agent(workspace_id, agent_id)
        end

        :ok

      {:ok, _} ->
        :ok

      {:error, reason} ->
        BoomLooper.EventLog.warning("workspace", "Failed to replay agent log: #{inspect(reason)}")
    end
  end

  defp start_restored_agent(workspace_id, agent_id) do
    opts = [id: agent_id, resume: true]

    case BoomLooper.WorkspaceGroup.start_agent(workspace_id, opts) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        BoomLooper.EventLog.warning("workspace", "Failed to resume agent #{agent_id}: #{inspect(reason)}")
    end
  end
end
