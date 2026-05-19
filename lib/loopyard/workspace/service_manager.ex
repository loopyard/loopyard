defmodule Loopyard.Workspace.ServiceManager do
  @moduledoc """
  GenServer managing Docker Compose services for a workspace.

  Agents write docker-compose.yml directly via loopyard-container tools.
  This module runs `docker compose up/down` and monitors container health.
  """
  use GenServer, restart: :transient

  alias Loopyard.{Compose, RegistryHelper, Workspace}
  alias Loopyard.Workspace.ServiceStatus

  @status_table :service_status_cache

  defstruct [
    # virtual dir (~/.loopyard/workspaces/<id>) where compose file lives
    :project_dir,
    # original project dir (used for registry and broadcasts)
    :canonical_dir,
    :workspace_id,
    # code volume name (code-<workspace_id>)
    :volume_name,
    running: false
  ]

  # --- Public API ---

  def start_link(opts) do
    project_dir = Keyword.fetch!(opts, :project_dir)
    GenServer.start_link(__MODULE__, opts, name: via(project_dir))
  end

  def start_services(project_dir) do
    case RegistryHelper.call(
           Loopyard.ServiceManagerRegistry,
           project_dir,
           :start_services,
           600_000
         ) do
      {:ok, result} -> result
      {:error, :not_found} -> {:error, :service_manager_not_running}
    end
  end

  def stop_services(project_dir) do
    case RegistryHelper.call(
           Loopyard.ServiceManagerRegistry,
           project_dir,
           :stop_services,
           30_000
         ) do
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

  def service_exec(project_dir, service_name, command) do
    workspace_id = Workspace.workspace_id(project_dir)
    Compose.exec(project_dir, workspace_id, service_name, command)
  end

  def subscribe do
    Loopyard.Events.WorkspaceServices.subscribe()
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

    Task.Supervisor.start_child(Loopyard.TaskSupervisor, fn ->
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
          Loopyard.EventLog.error(
            "workspace:#{workspace_id}",
            "Async init failed: #{Exception.message(e)}"
          )
      catch
        :exit, reason ->
          Loopyard.EventLog.error(
            "workspace:#{workspace_id}",
            "Async init exited: #{inspect(reason)}"
          )
      end
    end)

    {:ok, state}
  end

  @impl true
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
    Loopyard.EventLog.info(
      "workspace:#{state.workspace_id}",
      "Reconnecting to existing compose containers"
    )

    # Reprocess compose to ensure port bindings go through the registry
    ensure_compose_ports(state)

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

  # Catchall handle_call — stays grouped with the specific ones above.
  def handle_call(msg, _from, state) do
    require Logger

    Logger.warning(
      "[ServiceManager] ws=#{state.workspace_id} unhandled call: #{inspect(msg, limit: 200)}"
    )

    :telemetry.execute(
      [:loopyard, :actor, :unknown_message],
      %{count: 1},
      %{
        actor: __MODULE__,
        workspace_id: state.workspace_id,
        kind: :call,
        msg: inspect(msg, limit: 200)
      }
    )

    {:reply, {:error, :unknown_call}, state}
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

  # Catchall handle_cast. Stays grouped with the other handle_casts
  # above.
  def handle_cast(msg, state) do
    require Logger

    Logger.warning(
      "[ServiceManager] ws=#{state.workspace_id} unhandled cast: #{inspect(msg, limit: 200)}"
    )

    :telemetry.execute(
      [:loopyard, :actor, :unknown_message],
      %{count: 1},
      %{
        actor: __MODULE__,
        workspace_id: state.workspace_id,
        kind: :cast,
        msg: inspect(msg, limit: 200)
      }
    )

    {:noreply, state}
  end

  # Catchall handle_info. ServiceManager has no specific handle_info
  # clauses today, but bogus OTP messages (DOWN, node up, etc.)
  # mustn't crash a hot-path GenServer.
  @impl true
  def handle_info(msg, state) do
    require Logger

    Logger.warning(
      "[ServiceManager] ws=#{state.workspace_id} unhandled info: #{inspect(msg, limit: 200)}"
    )

    :telemetry.execute(
      [:loopyard, :actor, :unknown_message],
      %{count: 1},
      %{
        actor: __MODULE__,
        workspace_id: state.workspace_id,
        kind: :info,
        msg: inspect(msg, limit: 200)
      }
    )

    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Containers persist across ServiceManager restarts. State lives in
    # volumes + ETF logs, and init/1 reconnects via `Compose.ps` on the
    # next start. Only the explicit `stop_services/1` path tears containers
    # down — crash / shutdown / supervisor restart keeps them running so
    # the user's work survives a BEAM restart.
    Loopyard.EventLog.info(
      "workspace:#{state.workspace_id}",
      "ServiceManager stopping — containers left running"
    )

    :ok
  end

  # --- Private ---

  defp do_start(state) do
    # Ensure code volume exists (all workspaces are now volume-based)
    volume_name = state.volume_name || "code-#{state.workspace_id}"
    Loopyard.VolumeManager.create_volume(volume_name)

    # Local projects: Mutagen handles host ↔ volume sync (via SyncMonitor).
    # We do NOT copy code here — Mutagen is the single path for getting
    # files into the volume. If Mutagen isn't installed, the workspace
    # will start but the volume will be empty until sync is configured.

    # Check for agent-written compose file in the volume
    compose_path = Compose.compose_path(state.project_dir)

    # mkdir_p non-bang — disk-full / permission errors surface as
    # {:error, reason} instead of raising inside the GenServer.
    case File.mkdir_p(Path.dirname(compose_path)) do
      :ok ->
        :ok

      {:error, reason} ->
        Loopyard.EventLog.error(
          "workspace:#{state.workspace_id}",
          "Could not create compose dir #{Path.dirname(compose_path)}: " <>
            "#{:file.format_error(reason)}. Cluster won't start until the " <>
            "disk/permission issue is fixed."
        )
    end

    # Port assignments now come from Loopyard.PortRegistry inside
    # process_agent_compose/3 — no more port_map capture at this layer.
    has_compose =
      case Loopyard.VolumeManager.read_file(
             volume_name,
             ".loopyard/workspace/docker-compose.yml"
           ) do
        {:ok, content} when content != "" ->
          case Compose.process_agent_compose(content, state.workspace_id) do
            {:ok, processed} ->
              # Disk-full / permission denied here used to raise inside
              # handle_call — supervisor would quarantine the GenServer
              # after 5 retries. Now surfaces as a clean EventLog line
              # + cluster just doesn't start this tick. Next retry (user
              # click on Start) will try again.
              case File.write(compose_path, processed) do
                :ok ->
                  true

                {:error, reason} ->
                  Loopyard.EventLog.error(
                    "workspace:#{state.workspace_id}",
                    "Compose file write failed: #{:file.format_error(reason)}. " <>
                      "Fix the disk/permissions on #{compose_path} and click Start again."
                  )

                  false
              end

            {:error, reason} ->
              # Don't crash the cluster, but log an actionable error so the
              # sidebar / agent `logs` tool surface it. The message from
              # `validate_no_host_mounts` already tells the reader what to
              # change and why.
              Loopyard.EventLog.error(
                "workspace:#{state.workspace_id}",
                "Agent compose file rejected — cluster will not start until " <>
                  "it's fixed.\n\n#{reason}"
              )

              false
          end

        _ ->
          false
      end

    if has_compose do
      Loopyard.EventLog.info("workspace:#{state.workspace_id}", "Starting compose services")

      case Compose.up(state.project_dir, state.workspace_id) do
        {:ok, _} ->
          # Discover Docker's ephemeral ports and start proxies
          discover_docker_ports(state.workspace_id)

          replay_agent_log(state.project_dir, state.workspace_id)
          new_state = %{state | running: true, volume_name: volume_name}
          notify_source_container_up(state.workspace_id)
          broadcast_service_update(new_state)
          broadcast_compose_result(state.workspace_id, :ok)
          {:ok, new_state}

        {:error, reason} ->
          Loopyard.EventLog.error(
            "workspace:#{state.workspace_id}",
            "Compose up failed: #{reason}"
          )

          broadcast_compose_result(state.workspace_id, {:error, reason})
          {:error, reason}
      end
    else
      Loopyard.EventLog.info(
        "workspace:#{state.workspace_id}",
        "No docker-compose.yml yet, waiting for agent to write it"
      )

      replay_agent_log(state.project_dir, state.workspace_id)
      # No compose file → nothing actually starting. Unblock the LV's
      # :starting pill so it can settle back to :stopped instead of
      # spinning forever waiting for a cluster that was never going
      # to come up.
      broadcast_compose_result(
        state.workspace_id,
        {:error, "No docker-compose.yml — agent needs to write one"}
      )

      {:ok, %{state | volume_name: volume_name}}
    end
  end

  # Re-read the compose file from the volume, reprocess it through the
  # registry (so all port bindings become 127.0.0.1:registry_port), and
  # `docker compose up -d` to apply. This is idempotent — if the compose
  # file is already correct, the up is a no-op.
  defp ensure_compose_ports(state) do
    volume_name = state.volume_name || "code-#{state.workspace_id}"
    compose_path = Compose.compose_path(state.project_dir)

    with {:ok, content} when content != "" <-
           Loopyard.VolumeManager.read_file(
             volume_name,
             ".loopyard/workspace/docker-compose.yml"
           ),
         {:ok, processed} <- Compose.process_agent_compose(content, state.workspace_id) do
      # Only re-up if the processed file differs from what's on disk.
      current = File.read(compose_path)

      if current != {:ok, processed} do
        File.mkdir_p!(Path.dirname(compose_path))
        File.write!(compose_path, processed)
        Compose.up(state.project_dir, state.workspace_id)

        Loopyard.EventLog.info(
          "workspace:#{state.workspace_id}",
          "Reprocessed compose to enforce loopback port bindings"
        )
      end
    else
      _ -> :ok
    end
  rescue
    e ->
      Loopyard.EventLog.warning(
        "workspace:#{state.workspace_id}",
        "ensure_compose_ports failed: #{Exception.message(e)}"
      )
  end

  defp do_stop(state) do
    notify_source_container_down(state.workspace_id)

    case Compose.down(state.project_dir, state.workspace_id) do
      {:ok, _} ->
        broadcast_compose_result(state.workspace_id, :ok)
        :ok

      {:error, reason} ->
        require Logger
        Logger.warning("[ServiceManager] compose down failed: #{reason}")
        broadcast_compose_result(state.workspace_id, {:error, reason})
    end
  end

  # Notify the Source adapter that this workspace's container is up/down.
  # Local workspaces use this to start/pause their mutagen sync session.
  # Safe to call for any source — no-ops on GitHub and unregistered workspaces.
  # After compose up or reconnect, inspect running containers to find
  # Docker's ephemeral port for each service with a registry entry.
  # Calls PortRegistry.set_docker_port which starts the proxy.
  defp discover_docker_ports(workspace_id) do
    project_name = Compose.project_name(workspace_id)
    containers = Loopyard.Docker.Observer.containers_for(workspace_id)

    for entry <- Loopyard.PortRegistry.list_for_workspace(workspace_id) do
      container_name = "#{project_name}-#{entry.service}-1"
      container = Enum.find(containers, &(&1.name == container_name))

      if container && container[:host_ports] do
        docker_port =
          container.host_ports[entry.container_port] ||
            container.host_ports[to_string(entry.container_port)]

        if docker_port do
          dp = if is_binary(docker_port), do: String.to_integer(docker_port), else: docker_port

          Loopyard.PortRegistry.set_docker_port(
            workspace_id,
            entry.service,
            entry.container_port,
            dp
          )
        end
      end
    end
  rescue
    e ->
      require Logger
      Logger.warning("[ServiceManager] discover_docker_ports failed: #{Exception.message(e)}")
  end

  defp notify_source_container_up(workspace_id) do
    with %{project_id: project_id} = workspace <-
           Loopyard.ProjectRegistry.get_workspace(workspace_id),
         project when is_map(project) <- Loopyard.ProjectRegistry.get_project(project_id) do
      Loopyard.Source.for_project(project).on_container_up(workspace)
    else
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  defp notify_source_container_down(workspace_id) do
    with %{project_id: project_id} = workspace <-
           Loopyard.ProjectRegistry.get_workspace(workspace_id),
         project when is_map(project) <- Loopyard.ProjectRegistry.get_project(project_id) do
      Loopyard.Source.for_project(project).on_container_down(workspace)
    else
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  # Fire a notification that a compose up/down attempt has completed —
  # either succeeded or definitively failed. LVs in :starting / :stopping
  # pick this up to transition out of the transitional state so they're
  # not stuck waiting for a broadcast that will never come.
  defp broadcast_compose_result(workspace_id, result) do
    Loopyard.Events.WorkspaceServices.publish(%Loopyard.Events.WorkspaceServices.ComposeResult{
      workspace_id: workspace_id,
      result: result
    })
  end

  defp broadcast_service_update(state) do
    # Use ServiceStatus for consistent enumeration across all callers
    all_statuses = ServiceStatus.for_workspace(state.project_dir)

    # Use canonical_dir for broadcasts so subscribers can match on the original path
    broadcast_dir = state.canonical_dir || state.project_dir

    # Cache in ETS so service_status/1 never blocks on the GenServer
    :ets.insert(@status_table, {broadcast_dir, all_statuses})

    # Notification-only. Subscribers re-read from the ETS cache or the
    # Observer. Shipping the statuses blob in the broadcast was wasted
    # serialization across every connected LiveView — none of them
    # actually used the payload.
    Loopyard.Events.WorkspaceServices.publish(%Loopyard.Events.WorkspaceServices.ServicesUpdated{
      path: broadcast_dir
    })
  end

  defp via(project_dir) do
    {:via, Registry, {Loopyard.ServiceManagerRegistry, project_dir}}
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

  defp replay_agent_log(_project_dir, workspace_id) do
    log_path = Loopyard.ChatAgent.Persistence.log_path(workspace_id)

    # Log is append-only. Compact it at boot if it's grown past the
    # threshold so replay stays fast on long-running workspaces.
    case Loopyard.AgentLog.maybe_compact(log_path: log_path, version: @log_version) do
      {:ok, %{before: b, after: a, agents: ag, messages: m}} when b != a ->
        Loopyard.EventLog.info(
          "workspace:#{workspace_id}",
          "Compacted agent log: #{b} → #{a} bytes (#{ag} agents, #{m} messages)"
        )

      _ ->
        :ok
    end

    # Use fallback-aware replay: if the primary log is corrupt, automatically
    # try <path>.prev (maintained by the Checkpointer via
    # compact_keep_previous/1). Emits :fallback_used telemetry on recovery
    # so /system/recovery can surface boot-time corruption events.
    replay_result =
      Loopyard.AgentLog.replay_with_fallback(
        log_path: log_path,
        version: @log_version,
        ets_table: :chat_agents,
        telemetry_metadata: %{workspace_id: workspace_id}
      )

    case replay_result do
      {:ok, agents, source} when map_size(agents) > 0 ->
        source_note =
          case source do
            :primary -> ""
            :previous -> " (recovered from .prev — primary log was corrupt)"
          end

        Loopyard.EventLog.info(
          "workspace",
          "Restored #{map_size(agents)} agent(s) from log#{source_note}, starting..."
        )

        for {agent_id, _agent_data} <- agents do
          start_restored_agent(workspace_id, agent_id)
        end

        :ok

      {:ok, _, _source} ->
        :ok

      {:error, {:version_mismatch, file: file_v, requested: @log_version}} ->
        # Attempt migration before giving up
        case migrate_log(log_path, file_v) do
          :ok ->
            Loopyard.EventLog.info(
              "workspace",
              "Migrated agent log from v#{file_v} to v#{@log_version}"
            )

            # Retry replay after successful migration
            replay_agent_log(nil, workspace_id)

          {:error, :no_migration_path} ->
            Loopyard.EventLog.warning(
              "workspace",
              "Agent log version mismatch: file is v#{file_v}, expected v#{@log_version}. " <>
                "No migration path available. Agents not restored."
            )

          {:error, reason} ->
            Loopyard.EventLog.warning(
              "workspace",
              "Failed to migrate agent log from v#{file_v}: #{inspect(reason)}. Agents not restored."
            )
        end

      {:error, reason} ->
        Loopyard.EventLog.warning("workspace", "Failed to replay agent log: #{inspect(reason)}")
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
        case Loopyard.AgentLog.migrate(
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
    case Registry.lookup(Loopyard.ChatAgentRegistry, agent_id) do
      [{_pid, _}] ->
        :ok

      [] ->
        # Don't restart agents that were stopped or crashed
        case :ets.lookup(:chat_agents, agent_id) do
          [{_, %{status: status}}] when status in [:stopped, :crashed] ->
            :ok

          _ ->
            opts = [id: agent_id, resume: true, started_by: "log_replay"]

            case Loopyard.WorkspaceGroup.start_agent(workspace_id, opts) do
              {:ok, _pid} ->
                :ok

              {:error, reason} ->
                Loopyard.EventLog.warning(
                  "workspace",
                  "Failed to resume agent #{agent_id}: #{inspect(reason)}"
                )
            end
        end
    end
  end
end
