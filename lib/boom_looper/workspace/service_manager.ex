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
    :project_dir,       # effective project dir (where compose file lives)
    :canonical_dir,     # original project dir (used for registry and broadcasts)
    :workspace_id,
    :volume_based,      # always true now (all workspaces are volume-based)
    :volume_name,       # code volume name
    :source_path,       # original local path (for local projects migrated to volume)
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
      [{pid, _}] -> GenServer.call(pid, :service_status, 60_000)
      [] -> {:ok, []}
    end
  end

  def restart_workspace_container(project_dir) do
    case Registry.lookup(BoomLooper.ServiceManagerRegistry, project_dir) do
      [{pid, _}] -> GenServer.call(pid, :restart, 600_000)
      [] -> :ok
    end
  end

  @doc """
  Rebuild dev containers only, keeping workspace container running.
  Workspace container stays up so agents can continue exec'ing into it.
  """
  def restart_dev_streaming(project_dir, callback) when is_function(callback, 1) do
    workspace_id = Workspace.workspace_id(project_dir)

    volume_name = "code-#{workspace_id}"

    # Stop only dev containers (not workspace)
    case Workspace.load_from_volume(volume_name) do
      {:ok, ws} ->
        Enum.each(ws.processes, fn p ->
          Compose.compose(project_dir, workspace_id, ["stop", p.name], timeout: 30_000)
        end)
      _ -> :ok
    end

    # Regenerate compose file with updated config from volume
    case Workspace.load_from_volume(volume_name) do
      {:ok, ws} ->
        content = Compose.generate(ws, project_dir, workspace_id)
        compose_path = Compose.compose_path(project_dir)
        File.mkdir_p!(Path.dirname(compose_path))
        File.write!(compose_path, content)
      _ -> :ok
    end

    # Rebuild and start dev containers only
    # docker compose up --build <service> rebuilds just that service
    case Workspace.load_from_volume(volume_name) do
      {:ok, ws} when ws.processes != [] ->
        process_names = Enum.map(ws.processes, & &1.name)
        result = Compose.up_services_stream(project_dir, workspace_id, process_names, callback)

        # Reconnect state
        case Registry.lookup(BoomLooper.ServiceManagerRegistry, project_dir) do
          [{pid, _}] -> GenServer.call(pid, {:reconnect, ws}, 30_000)
          [] -> :ok
        end

        result

      _ ->
        {:ok, "No dev processes configured"}
    end
  end

  @doc "Stop containers, rebuild with streaming output, then reconnect state."
  def restart_workspace_streaming(project_dir, callback) when is_function(callback, 1) do
    workspace_id = Workspace.workspace_id(project_dir)
    volume_name = "code-#{workspace_id}"

    Compose.down(project_dir, workspace_id)

    # Write compose file from volume config
    case Workspace.load_from_volume(volume_name) do
      {:ok, ws} ->
        content = Compose.generate(ws, project_dir, workspace_id)
        compose_path = Compose.compose_path(project_dir)
        File.mkdir_p!(Path.dirname(compose_path))
        File.write!(compose_path, content)
      _ -> :ok
    end

    result = Compose.up_stream(project_dir, workspace_id, callback)

    case Registry.lookup(BoomLooper.ServiceManagerRegistry, project_dir) do
      [{pid, _}] ->
        case Workspace.load_from_volume(volume_name) do
          {:ok, ws} -> GenServer.call(pid, {:reconnect, ws}, 30_000)
          _ -> :ok
        end
      [] -> :ok
    end

    result
  end

  @doc "Stop containers, rebuild with streaming output for volume-based workspaces."
  def restart_workspace_streaming_volume(workspace_id, volume_name, callback) when is_function(callback, 1) do
    # Use virtual project dir
    project_dir = Path.join([Workspace.home_dir(), "workspaces", workspace_id])
    File.mkdir_p!(project_dir)

    Compose.down(project_dir, workspace_id)

    # Load config from volume and write compose file
    case Workspace.load_from_volume(volume_name) do
      {:ok, ws} ->
        content = Compose.generate(ws, project_dir, workspace_id)
        compose_path = Compose.compose_path(project_dir)
        File.mkdir_p!(Path.dirname(compose_path))
        File.write!(compose_path, content)

      _ -> :ok
    end

    result = Compose.up_stream(project_dir, workspace_id, callback)

    case Registry.lookup(BoomLooper.ServiceManagerRegistry, project_dir) do
      [{pid, _}] ->
        case Workspace.load_from_volume(volume_name) do
          {:ok, ws} -> GenServer.call(pid, {:reconnect, ws}, 30_000)
          _ -> :ok
        end
      [] -> :ok
    end

    result
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
    workspace_id = Keyword.get(opts, :workspace_id) || Workspace.workspace_id(project_dir)
    volume_based = Keyword.get(opts, :volume_based, false)
    volume_name = Keyword.get(opts, :volume_name) || "code-#{workspace_id}"

    # ALL workspaces are now volume-based
    # For local paths, migrate code to volume on first run
    {effective_project_dir, volume_based, source_path} = if volume_based do
      # Already volume-based (git URL project)
      dir = Path.join([Workspace.home_dir(), "workspaces", workspace_id])
      File.mkdir_p!(dir)
      {dir, true, nil}
    else
      # Local path - migrate to volume
      dir = Path.join([Workspace.home_dir(), "workspaces", workspace_id])
      File.mkdir_p!(dir)
      {dir, true, project_dir}
    end

    state = %__MODULE__{
      project_dir: effective_project_dir,
      canonical_dir: project_dir,  # original path for registry/broadcasts
      workspace_id: workspace_id,
      volume_based: volume_based,
      volume_name: volume_name,
      source_path: source_path
    }

    # Load workspace config from volume (all workspaces are volume-based now)
    ws_result = Workspace.load_from_volume(volume_name)

    # Always try to start services - workspace container uses fixed alpine image
    # and can run even without a project Dockerfile configured
    self_pid = self()
    Task.start(fn ->
      case Compose.ps(effective_project_dir, workspace_id) do
        {:ok, running} when running != [] ->
          # Containers already running — reconnect state without rebuilding
          ws = case ws_result do
            {:ok, ws} -> ws
            _ -> %Workspace{}
          end
          GenServer.call(self_pid, {:reconnect, ws}, 30_000)

        _ ->
          # No running containers — do a full start
          GenServer.call(self_pid, :start_services, 600_000)
      end
    end)

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
    # Ensure code volume exists (all workspaces are now volume-based)
    volume_name = state.volume_name || "code-#{state.workspace_id}"
    BoomLooper.VolumeManager.create_volume(volume_name)

    # For local path projects, copy code to volume if not already done
    if state.source_path && !BoomLooper.VolumeManager.volume_has_code?(volume_name) do
      BoomLooper.EventLog.info("workspace:#{state.workspace_id}",
        "Copying code from #{state.source_path} to volume #{volume_name}")

      case BoomLooper.VolumeManager.copy_to_volume(volume_name, state.source_path) do
        {:ok, _} ->
          BoomLooper.EventLog.info("workspace:#{state.workspace_id}", "Code copied successfully")

        {:error, reason} ->
          BoomLooper.EventLog.error("workspace:#{state.workspace_id}", "Failed to copy code: #{reason}")
      end
    end

    # Load config - use default empty workspace if none exists
    ws = case load_workspace_config(state) do
      {:ok, ws} -> ws
      _ -> %Workspace{}
    end

    # Generate and write compose file
    content = Compose.generate(ws, state.project_dir, state.workspace_id)
    compose_path = Compose.compose_path(state.project_dir)
    File.mkdir_p!(Path.dirname(compose_path))
    File.write!(compose_path, content)

    # If there's no dockerfile and no services, nothing to start yet.
    # The setup agent will configure the workspace and trigger a rebuild.
    has_services = ws.dockerfile != nil || ws.services != [] || ws.processes != []

    if has_services do
      BoomLooper.EventLog.info("workspace:#{state.workspace_id}", "Starting compose services")

      case Compose.up(state.project_dir, state.workspace_id) do
        {:ok, _} ->
          replay_agent_log(state.project_dir, state.workspace_id)

          services = Map.new(ws.services, fn s -> {s.name, s} end)
          all_names = Enum.map(ws.processes, & &1.name) ++ Enum.map(ws.services, & &1.name) ++ ["workspace"]
          initial_health = Map.new(all_names, fn name -> {name, :started} end)

          new_state = %{state |
            services: services,
            processes: ws.processes,
            running: true,
            service_health: initial_health,
            volume_name: volume_name
          }
          broadcast_service_update(new_state)
          {:ok, new_state}

        {:error, reason} ->
          BoomLooper.EventLog.error("workspace:#{state.workspace_id}", "Compose up failed: #{reason}")
          {:error, reason}
      end
    else
      BoomLooper.EventLog.info("workspace:#{state.workspace_id}", "No services configured yet, waiting for setup")
      replay_agent_log(state.project_dir, state.workspace_id)
      {:ok, %{state | volume_name: volume_name}}
    end
  end

  defp load_workspace_config(state) do
    # All workspaces are now volume-based
    Workspace.load_from_volume(state.volume_name)
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

    # Use canonical_dir for broadcasts so subscribers can match on the original path
    broadcast_dir = state.canonical_dir || state.project_dir

    Phoenix.PubSub.broadcast(
      BoomLooper.PubSub,
      @services_topic,
      {:services_updated, broadcast_dir, all_statuses}
    )
  end

  defp via(project_dir) do
    {:via, Registry, {BoomLooper.ServiceManagerRegistry, project_dir}}
  end

  # --- Agent Log Versioning ---
  #
  # Agent logs use file-level versioning. The version is stored in the first
  # record (meta header) and checked on every replay.
  #
  # Migration strategy:
  # - Migration happens HERE, on startup, before any agents are created
  # - This means no concurrent writes during migration (agents don't exist yet)
  # - If we ever need "hot" migration while agents are running, we'd need a
  #   GenServer coordinator that queues writes during migration. Don't build
  #   that until we actually need it.
  #
  # When to bump @log_version:
  # - DO bump: Structural changes to event tuples (adding/removing elements)
  # - DON'T bump: Adding new keys to maps (maps are extensible, old code ignores new keys)
  #
  # To add a new version:
  # 1. Bump @log_version
  # 2. Add transformer in migrate_log/2: {@log_version - 1, @log_version} => fn ...
  # 3. The migration chain handles multi-version jumps (v1→v2→v3)

  @log_version 1

  defp replay_agent_log(project_dir, workspace_id) do
    log_path = Path.join([project_dir, ".boomlooper", "workspace", "agents.log"])

    case BoomLooper.AgentLog.replay(log_path: log_path, version: @log_version, ets_table: :chat_agents) do
      {:ok, agents} when map_size(agents) > 0 ->
        BoomLooper.EventLog.info("workspace", "Restored #{map_size(agents)} agent(s) from log, starting...")

        for {agent_id, _agent_data} <- agents do
          start_restored_agent(workspace_id, agent_id)
        end

        :ok

      {:ok, _} ->
        :ok

      {:error, {:version_mismatch, file: file_v, requested: @log_version}} ->
        # Attempt migration before giving up
        case migrate_log(log_path, file_v) do
          :ok ->
            BoomLooper.EventLog.info("workspace", "Migrated agent log from v#{file_v} to v#{@log_version}")
            # Retry replay after successful migration
            replay_agent_log(project_dir, workspace_id)

          {:error, :no_migration_path} ->
            BoomLooper.EventLog.warning("workspace",
              "Agent log version mismatch: file is v#{file_v}, expected v#{@log_version}. " <>
              "No migration path available. Agents not restored.")

          {:error, reason} ->
            BoomLooper.EventLog.warning("workspace",
              "Failed to migrate agent log from v#{file_v}: #{inspect(reason)}. Agents not restored.")
        end

      {:error, reason} ->
        BoomLooper.EventLog.warning("workspace", "Failed to replay agent log: #{inspect(reason)}")
    end
  end

  # Migrate log file from old version to @log_version.
  # Handles multi-step migrations (e.g., v1→v2→v3) by chaining.
  defp migrate_log(log_path, from_version) when from_version < @log_version do
    # Find next version in chain
    next_version = from_version + 1

    case migration_transformer(from_version, next_version) do
      nil ->
        {:error, :no_migration_path}

      transformer ->
        case BoomLooper.AgentLog.migrate(
          log_path: log_path,
          from: from_version,
          to: next_version,
          transformer: transformer
        ) do
          :ok when next_version == @log_version ->
            :ok

          :ok ->
            # Continue chain to reach @log_version
            migrate_log(log_path, next_version)

          error ->
            error
        end
    end
  end

  defp migrate_log(_log_path, from_version) when from_version > @log_version do
    # File is newer than code - can't downgrade
    {:error, :no_migration_path}
  end

  # Define transformers for each version step.
  # Return nil if no migration exists for that step.
  #
  # Example for future v1→v2 migration:
  #
  #   defp migration_transformer(1, 2) do
  #     fn
  #       {:msg, agent_id, data} ->
  #         # Example: rename field
  #         {:msg, agent_id, Map.put(data, :new_field, Map.get(data, :old_field))}
  #       other ->
  #         other
  #     end
  #   end
  #
  defp migration_transformer(_from, _to), do: nil

  defp start_restored_agent(workspace_id, agent_id) do
    # Don't start if the agent process is already running
    case Registry.lookup(BoomLooper.ChatAgentRegistry, agent_id) do
      [{_pid, _}] ->
        :ok

      [] ->
        # Don't restart agents that were stopped or crashed
        case :ets.lookup(:chat_agents, agent_id) do
          [{_, %{status: status}}] when status in [:stopped, :crashed] ->
            :ok

          _ ->
            opts = [id: agent_id, resume: true, started_by: "log_replay"]

            case BoomLooper.WorkspaceGroup.start_agent(workspace_id, opts) do
              {:ok, _pid} ->
                :ok

              {:error, reason} ->
                BoomLooper.EventLog.warning("workspace", "Failed to resume agent #{agent_id}: #{inspect(reason)}")
            end
        end
    end
  end
end
