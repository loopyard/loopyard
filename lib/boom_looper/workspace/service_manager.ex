defmodule BoomLooper.Workspace.ServiceManager do
  @moduledoc """
  GenServer managing Docker Compose services for a workspace.

  Agents write docker-compose.yml directly via boom-looper-container tools.
  This module runs `docker compose up/down` and monitors container health.
  """
  use GenServer, restart: :transient

  alias BoomLooper.{Compose, RegistryHelper, Workspace}
  alias BoomLooper.Workspace.ServiceStatus

  @services_topic "workspace_services"
  @status_table :service_status_cache

  defstruct [
    :project_dir,       # virtual dir (~/.boomlooper/workspaces/<id>) where compose file lives
    :canonical_dir,     # original project dir (used for registry and broadcasts)
    :workspace_id,
    :volume_name,       # code volume name (code-<workspace_id>)
    running: false,
    rebuilding: false
  ]

  # --- Public API ---

  def start_link(opts) do
    project_dir = Keyword.fetch!(opts, :project_dir)
    GenServer.start_link(__MODULE__, opts, name: via(project_dir))
  end

  def start_services(project_dir) do
    case RegistryHelper.call(BoomLooper.ServiceManagerRegistry, project_dir, :start_services, 600_000) do
      {:ok, result} -> result
      {:error, :not_found} -> {:error, :service_manager_not_running}
    end
  end

  def stop_services(project_dir) do
    case RegistryHelper.call(BoomLooper.ServiceManagerRegistry, project_dir, :stop_services, 30_000) do
      {:ok, result} -> result
      {:error, :not_found} -> :ok
    end
  end

  def service_status(project_dir) do
    # Read from ETS cache — never blocks on the GenServer (which may be doing Docker ops)
    case :ets.lookup(@status_table, project_dir) do
      [{_, statuses}] -> {:ok, statuses}
      [] -> {:ok, []}
    end
  end

  def restart_workspace_container(project_dir) do
    case RegistryHelper.call(BoomLooper.ServiceManagerRegistry, project_dir, :restart, 600_000) do
      {:ok, result} -> result
      {:error, :not_found} -> :ok
    end
  end

  @doc """
  Rebuild dev containers only, keeping workspace container running.
  Workspace container stays up so agents can continue exec'ing into it.
  """
  def restart_dev_streaming(project_dir, callback) when is_function(callback, 1) do
    workspace_id = Workspace.workspace_id(project_dir)
    volume_name = Workspace.volume_name_for(workspace_id)
    effective_dir = Workspace.compose_dir(workspace_id)
    File.mkdir_p!(effective_dir)

    # Capture port assignments BEFORE stopping containers so we can pin them
    # Legacy port_map removed — registry owns port assignment now

    compose_path = Compose.compose_path(effective_dir)
    File.mkdir_p!(Path.dirname(compose_path))

    case BoomLooper.VolumeManager.read_file(volume_name, ".boomlooper/workspace/docker-compose.yml") do
      {:ok, content} when content != "" ->
        case Compose.process_agent_compose(content, workspace_id) do
          {:ok, processed} -> File.write!(compose_path, processed)
          {:error, reason} ->
            callback.("Error processing compose file: #{reason}\n")
            {:error, reason}
        end

      _ ->
        callback.("No docker-compose.yml found. Agent must write it first.\n")
        {:error, :no_compose_file}
    end

    # Stop dev containers (not workspace) - use compose ps to find them
    case Compose.ps(effective_dir, workspace_id) do
      {:ok, services} ->
        services
        |> Enum.filter(fn s -> s.name != "workspace" end)
        |> Enum.each(fn s ->
          Compose.compose(effective_dir, workspace_id, ["stop", s.name], timeout: 30_000)
        end)
      _ -> :ok
    end

    # Find services to start (everything except workspace)
    result = case Compose.compose(effective_dir, workspace_id, ["config", "--services"]) do
      {:ok, output} ->
        services = output |> String.trim() |> String.split("\n", trim: true) |> Enum.reject(&(&1 == "workspace"))
        if services != [] do
          Compose.up_services_stream(effective_dir, workspace_id, services, callback)
        else
          {:ok, "No services to start"}
        end
      _ ->
        {:ok, "No services configured"}
    end

    # Reconnect state
    case RegistryHelper.call(BoomLooper.ServiceManagerRegistry, project_dir, :reconnect, 30_000) do
      {:ok, result} -> result
      {:error, :not_found} -> :ok
    end

    result
  end

  @doc "Stop containers, rebuild with streaming output, then reconnect state."
  def restart_workspace_streaming(project_dir, callback) when is_function(callback, 1) do
    workspace_id = Workspace.workspace_id(project_dir)
    volume_name = Workspace.volume_name_for(workspace_id)
    effective_dir = Workspace.compose_dir(workspace_id)
    File.mkdir_p!(effective_dir)

    # Capture ports BEFORE tearing down
    # Legacy port_map removed — registry owns port assignment now

    Compose.down(effective_dir, workspace_id)

    compose_path = Compose.compose_path(effective_dir)
    File.mkdir_p!(Path.dirname(compose_path))

    case BoomLooper.VolumeManager.read_file(volume_name, ".boomlooper/workspace/docker-compose.yml") do
      {:ok, content} when content != "" ->
        case Compose.process_agent_compose(content, workspace_id) do
          {:ok, processed} ->
            File.write!(compose_path, processed)
          {:error, reason} ->
            callback.("Error processing compose file: #{reason}\n")
        end

      _ ->
        callback.("No docker-compose.yml found. Agent must write it first.\n")
    end

    result = Compose.up_stream(effective_dir, workspace_id, callback)

    case RegistryHelper.call(BoomLooper.ServiceManagerRegistry, project_dir, :reconnect, 30_000) do
      {:ok, result} -> result
      {:error, :not_found} -> :ok
    end

    result
  end

  @doc "Stop containers, rebuild with streaming output for volume-based workspaces."
  def restart_workspace_streaming_volume(workspace_id, volume_name, callback) when is_function(callback, 1) do
    project_dir = Workspace.compose_dir(workspace_id)
    File.mkdir_p!(project_dir)

    # Legacy port_map removed — registry owns port assignment now

    Compose.down(project_dir, workspace_id)

    compose_path = Compose.compose_path(project_dir)
    File.mkdir_p!(Path.dirname(compose_path))

    case BoomLooper.VolumeManager.read_file(volume_name, ".boomlooper/workspace/docker-compose.yml") do
      {:ok, content} when content != "" ->
        case Compose.process_agent_compose(content, workspace_id) do
          {:ok, processed} -> File.write!(compose_path, processed)
          {:error, reason} -> callback.("Error processing compose file: #{reason}\n")
        end

      _ ->
        callback.("No docker-compose.yml found. Agent must write it first.\n")
    end

    result = Compose.up_stream(project_dir, workspace_id, callback)

    case RegistryHelper.call(BoomLooper.ServiceManagerRegistry, project_dir, :reconnect, 30_000) do
      {:ok, result} -> result
      {:error, :not_found} -> :ok
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
    volume_name = Workspace.volume_name_for(workspace_id)

    # All workspaces use a virtual dir for compose files + metadata
    effective_project_dir = Workspace.compose_dir(workspace_id)
    File.mkdir_p!(effective_project_dir)

    state = %__MODULE__{
      project_dir: effective_project_dir,
      canonical_dir: project_dir,
      workspace_id: workspace_id,
      volume_name: volume_name
    }

    # Seed the ETS cache immediately so service_status/1 returns something
    # even while async init is doing Docker ops
    :ets.insert(@status_table, {project_dir, []})

    # Try to start services async — never crash init, just log failures.
    # If this fails, the ServiceManager stays alive in an idle state and
    # can be retried via start_services/1 or rebuild.
    self_pid = self()
    Task.Supervisor.start_child(BoomLooper.TaskSupervisor, fn ->
      try do
        case Compose.ps(effective_project_dir, workspace_id) do
          {:ok, running} when running != [] ->
            # Containers already running — reconnect state without rebuilding
            GenServer.call(self_pid, :reconnect, 30_000)

          _ ->
            # No running containers — do a full start
            GenServer.call(self_pid, :start_services, 600_000)
        end
      rescue
        e ->
          BoomLooper.EventLog.error("workspace:#{workspace_id}",
            "Async init failed: #{Exception.message(e)}")
      catch
        :exit, reason ->
          BoomLooper.EventLog.error("workspace:#{workspace_id}",
            "Async init exited: #{inspect(reason)}")
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
  def handle_call(:reconnect, _from, state) do
    BoomLooper.EventLog.info("workspace:#{state.workspace_id}", "Reconnecting to existing compose containers")

    # Discover Docker's ephemeral ports and start proxies
    discover_docker_ports(state.workspace_id)

    # Replay agent log to restore agent state to ETS and start agents
    replay_agent_log(state.project_dir, state.workspace_id)

    new_state = %{state | running: true}
    broadcast_service_update(new_state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:stop_services, _from, state) do
    do_stop(state)
    new_state = %{state | running: false}
    broadcast_service_update(new_state)
    {:reply, :ok, new_state}
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
    broadcast_service_update(state)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Containers persist across ServiceManager restarts. State lives in
    # volumes + ETF logs, and init/1 reconnects via `Compose.ps` on the
    # next start. Only the explicit `stop_services/1` path tears containers
    # down — crash / shutdown / supervisor restart keeps them running so
    # the user's work survives a BEAM restart.
    BoomLooper.EventLog.info(
      "workspace:#{state.workspace_id}",
      "ServiceManager stopping — containers left running"
    )
    :ok
  end

  # --- Private ---

  defp do_start(state) do
    # Ensure code volume exists (all workspaces are now volume-based)
    volume_name = state.volume_name || "code-#{state.workspace_id}"
    BoomLooper.VolumeManager.create_volume(volume_name)

    # Local projects: Mutagen handles host ↔ volume sync (via SyncMonitor).
    # We do NOT copy code here — Mutagen is the single path for getting
    # files into the volume. If Mutagen isn't installed, the workspace
    # will start but the volume will be empty until sync is configured.

    # Check for agent-written compose file in the volume
    compose_path = Compose.compose_path(state.project_dir)
    File.mkdir_p!(Path.dirname(compose_path))

    has_compose = case BoomLooper.VolumeManager.read_file(volume_name, ".boomlooper/workspace/docker-compose.yml") do
      {:ok, content} when content != "" ->
        case Compose.process_agent_compose(content, state.workspace_id) do
          {:ok, processed} ->
            File.write!(compose_path, processed)
            true
          {:error, _} ->
            false
        end
      _ ->
        false
    end

    if has_compose do
      BoomLooper.EventLog.info("workspace:#{state.workspace_id}", "Starting compose services")

      case Compose.up(state.project_dir, state.workspace_id) do
        {:ok, _} ->
          # Discover Docker's ephemeral ports and start proxies
          discover_docker_ports(state.workspace_id)

          replay_agent_log(state.project_dir, state.workspace_id)
          new_state = %{state | running: true, volume_name: volume_name}
          notify_source_container_up(state.workspace_id)
          broadcast_service_update(new_state)
          {:ok, new_state}

        {:error, reason} ->
          BoomLooper.EventLog.error("workspace:#{state.workspace_id}", "Compose up failed: #{reason}")
          {:error, reason}
      end
    else
      BoomLooper.EventLog.info("workspace:#{state.workspace_id}", "No docker-compose.yml yet, waiting for agent to write it")
      replay_agent_log(state.project_dir, state.workspace_id)
      {:ok, %{state | volume_name: volume_name}}
    end
  end

  defp do_stop(state) do
    notify_source_container_down(state.workspace_id)

    case Compose.down(state.project_dir, state.workspace_id) do
      {:ok, _} -> :ok
      {:error, reason} ->
        require Logger
        Logger.warning("[ServiceManager] compose down failed: #{reason}")
    end
  end

  # After compose up or reconnect, inspect running containers to find
  # Docker's ephemeral port for each service with a registry entry.
  # Calls PortRegistry.set_docker_port which starts the proxy.
  defp discover_docker_ports(workspace_id) do
    project_name = Compose.project_name(workspace_id)
    containers = BoomLooper.Docker.Observer.containers_for(workspace_id)

    for entry <- BoomLooper.PortRegistry.list_for_workspace(workspace_id) do
      container_name = "#{project_name}-#{entry.service}-1"
      container = Enum.find(containers, &(&1.name == container_name))

      if container && container[:host_ports] do
        # host_ports is %{container_port => host_port}
        docker_port = container.host_ports[entry.container_port] ||
                      container.host_ports[to_string(entry.container_port)]

        if docker_port do
          dp = if is_binary(docker_port), do: String.to_integer(docker_port), else: docker_port
          BoomLooper.PortRegistry.set_docker_port(
            workspace_id, entry.service, entry.container_port, dp
          )
        end
      end
    end
  rescue
    e ->
      require Logger
      Logger.warning("[ServiceManager] discover_docker_ports failed: #{Exception.message(e)}")
  end

  # Notify the Source adapter that this workspace's container is up/down.
  # Local workspaces use this to start/pause their mutagen sync session.
  # Safe to call for any source — no-ops on GitHub and unregistered workspaces.
  defp notify_source_container_up(workspace_id) do
    with %{project_id: project_id} = workspace <- BoomLooper.ProjectRegistry.get_workspace(workspace_id),
         project when is_map(project) <- BoomLooper.ProjectRegistry.get_project(project_id) do
      BoomLooper.Source.for_project(project).on_container_up(workspace)
    else
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  defp notify_source_container_down(workspace_id) do
    with %{project_id: project_id} = workspace <- BoomLooper.ProjectRegistry.get_workspace(workspace_id),
         project when is_map(project) <- BoomLooper.ProjectRegistry.get_project(project_id) do
      BoomLooper.Source.for_project(project).on_container_down(workspace)
    else
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  defp broadcast_service_update(state) do
    # Use ServiceStatus for consistent enumeration across all callers
    all_statuses = ServiceStatus.for_workspace(state.project_dir)

    # Use canonical_dir for broadcasts so subscribers can match on the original path
    broadcast_dir = state.canonical_dir || state.project_dir

    # Cache in ETS so service_status/1 never blocks on the GenServer
    :ets.insert(@status_table, {broadcast_dir, all_statuses})

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
