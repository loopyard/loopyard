defmodule Loopyard.Application do
  @moduledoc false
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    # Generate a launch secret for CLI onramp
    secret = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    Application.put_env(:loopyard, :launch_secret, secret)

    # Reap ACP exec clients orphaned by a previous VM. `docker exec -i …
    # claude-code-acp` clients survive BEAM death (quiet pipes never EPIPE),
    # pile up across restarts, and hold kernel resources (they saturated the
    # Colima VM's inotify budget once — every session then hung at
    # session/new). At this point in boot NO supervisor has spawned a session
    # yet, so every matching client on the host is ours and stale. Silent
    # no-op when there are none (pkill exit 1).
    _ = System.cmd("pkill", ["-f", "exec claude-code-acp"], stderr_to_stdout: true)

    children = [
      # --- Infrastructure layer (survives web reloads) ---
      # StateKeeper owns ALL ETS tables — must start first.
      Loopyard.StateKeeper,
      Loopyard.LogBuffer,
      Loopyard.IExSession,
      # Resources janitor — monitors owner pids and releases tracked
      # OS/OTP resources when an owner goes DOWN. Must start AFTER
      # StateKeeper (needs :resource_registry ETS table) and BEFORE
      # any subsystem that calls Resources.track/4 (PortRegistry,
      # WorkspaceSupervisor). Plan: Move #7b.
      Loopyard.Resources.Janitor,
      {Phoenix.PubSub, name: Loopyard.PubSub},
      {Registry, keys: :unique, name: Loopyard.ChatAgentRegistry},
      # Per-workspace RestartController registry — one controller per
      # workspace tracks crash history and decides whether to respawn
      # or quarantine each ChatAgent.
      {Registry, keys: :unique, name: Loopyard.ChatAgent.RestartControllerRegistry},
      # Per-workspace Checkpointer registry — one checkpointer per
      # workspace owns the agent-log snapshot schedule. Move #8.
      {Registry, keys: :unique, name: Loopyard.AgentLog.CheckpointerRegistry},
      {Registry, keys: :unique, name: Loopyard.ServiceManagerRegistry},
      {Registry, keys: :unique, name: Loopyard.WorkspaceRegistry},
      {Registry, keys: :unique, name: Loopyard.WorkspaceAgentRegistry},
      {Registry, keys: :unique, name: Loopyard.SyncMonitorRegistry},
      {Registry, keys: :unique, name: Loopyard.TerminalRegistry},
      # Workspace.Setup uses this to track in-flight setup tasks per
      # workspace_id — prevents duplicate concurrent setups, gives the
      # destructor a pid to kill on workspace removal.
      {Registry, keys: :unique, name: Loopyard.Workspace.Setup.Registry},
      {DynamicSupervisor, name: Loopyard.TerminalSupervisor, strategy: :one_for_one},
      {Task.Supervisor, name: Loopyard.TaskSupervisor},
      # Global home for agents NOT scoped to a workspace (e.g. the Workstation
      # agent). Workspace agents live under their WorkspaceGroup's
      # AgentSupervisor; ChatAgent.do_start_agent falls back here when
      # workspace_id is nil.
      {DynamicSupervisor, name: Loopyard.AgentSupervisor, strategy: :one_for_one},
      Loopyard.WorkspaceSupervisor,
      Loopyard.PortRegistry,
      {Registry, keys: :unique, name: Loopyard.PortExposerRegistry},
      {DynamicSupervisor, name: Loopyard.PortExposerSupervisor, strategy: :one_for_one},
      Loopyard.SSHServer,
      Loopyard.HostExposer,

      # Docker event-driven cache — starts the event stream + initial
      # snapshot so LiveViews can read container/volume state from ETS
      # instantly on mount. Must start after PubSub (broadcasts) and
      # before Endpoint (first LiveView mount).
      Loopyard.Docker.Observer,

      # Events tap — subscribes to every Loopyard global topic and
      # ring-buffers broadcasts with timestamps. Drives /system/events.
      # Must start after PubSub; order vs. Observer doesn't matter.
      Loopyard.Events.Tap,

      # Aural channels are now lazy-started by the package's
      # DynamicSupervisor — host doesn't add anything here.

      # Saga recorder — attaches to Loopyard.Saga telemetry and
      # keeps the last 100 runs in ETS for /system/sagas. Move #7a.
      # Must start before the first saga runs (which happens on any
      # workspace start / agent boot, i.e. well after app boot).
      Loopyard.Saga.Recorder,

      # Single writer for the app-wide saga journal. All Journal.append/1
      # calls route through it so appends can't interleave with compaction.
      # Must start before the first saga runs and before boot-time saga
      # resume (safe_restore "Saga.Journal" in start/2 below).
      Loopyard.Saga.Journal.Writer,

      # Periodic reconciler: diffs :chat_agents ETS against
      # ChatAgentRegistry every 30s and corrects drift where
      # Registry is authoritative. Must start after StateKeeper
      # (reads ETS) and ChatAgentRegistry (looks up pids).
      Loopyard.Agent.Reconciler,

      # Event-driven per-workspace changed-file counts (overview ±N badge).
      # Subscribes to agent StatusChanged; recomputes async; ETS via
      # StateKeeper's :ws_change_counts. Inert when :change_counts_enabled?
      # is false (test env).
      Loopyard.ChangeCounts,

      # --- Web layer (can restart independently) ---
      LoopyardWeb.Endpoint,

      # Dedicated MCP-over-HTTP listener for in-container ACP harnesses. Its own
      # Bandit endpoint on 0.0.0.0:<port> (separate from the loopback-only main
      # endpoint) so a workspace container can reach Loopyard's control-plane
      # tools via host.docker.internal — every call bearer-authed + agent-scoped.
      # nil (disabled, e.g. in test) is filtered out of the child list below.
      LoopyardWeb.MCP.Listener.child_spec_or_nil(),

      # Activity → chime bridge (#61). A web-edge SUBSCRIBER of the activity
      # stream — decorative sound, fully rip-out-able (the core has no idea it
      # exists; enforced by the sound boundary test). Started by module name
      # only, so no Aural reference leaks into the core here.
      LoopyardWeb.ActivitySound
    ]

    # Drop any nil children (e.g. the MCP listener when disabled in test).
    children = Enum.reject(children, &is_nil/1)

    # Higher max_restarts: the child list includes modules from multiple
    # development branches. A crashing child shouldn't kill the entire
    # supervisor — let it restart more aggressively before giving up.
    opts = [
      strategy: :one_for_one,
      name: Loopyard.Supervisor,
      max_restarts: 20,
      max_seconds: 10
    ]

    result = Supervisor.start_link(children, opts)

    # Attach the slow-mount logger so we get a loud warning if any
    # LiveView callback exceeds 500ms in production. The :timer.tc
    # mount tests catch this locally; this is the prod safety net.
    LoopyardWeb.SlowMountLogger.attach()

    # EventLog handler captures loopyard-tagged Logger events into ETS
    # EventLog now writes directly to ETS AND emits to Logger

    # Warn loudly if mutagen isn't installed — Local workspaces need it for
    # host ↔ volume sync. GitHub workspaces still work without it.
    unless Loopyard.Source.Local.Mutagen.installed?() do
      Logger.warning(
        "[Loopyard] mutagen not found on $PATH. Local workspaces will not sync " <>
          "with the host. Install it with: brew bundle install"
      )
    end

    # Detect Docker credential store misconfiguration. If credsStore is
    # set to "desktop" but Docker Desktop isn't running (colima users),
    # every docker pull/build hangs waiting for docker-credential-desktop.
    check_docker_creds_store()

    # Restore port assignments BEFORE projects — ProjectRegistry.restore
    # calls Compose.process_agent_compose which calls PortRegistry.assign.
    # If ports aren't restored first, assign creates fresh entries with
    # exposed: false, then persists them to disk, overwriting the saved
    # exposed: true. User has to re-open every port on every restart.
    safe_restore("PortRegistry", fn -> Loopyard.PortRegistry.restore() end)
    safe_restore("HostExposer", fn -> Loopyard.HostExposer.restore() end)

    # Restore persisted projects from ~/.loopyard/projects.json
    # ServiceManager will reconnect to any running containers. Wrapped in
    # safe_restore so a corrupt projects.json (ProjectStore.load raises)
    # degrades the app instead of aborting Application.start — and leaves
    # the file untouched for recovery.
    safe_restore("ProjectRegistry", fn -> Loopyard.ProjectRegistry.restore() end)

    # Restore canonical-backed projects (#19) from canonical_projects.json.
    safe_restore("CanonicalProjects", fn -> Loopyard.Onboarding.restore() end)

    # Surface any workspaces whose setup saga was running when the BEAM
    # last died. We mark them :failed with `:interrupted_by_restart` so
    # the operator can click Retry — auto-resume is too risky (host
    # paths can move, partial state can confuse retries).
    safe_restore("Workspace.Setup", fn ->
      case Loopyard.Workspace.Setup.recover_on_boot() do
        0 ->
          :ok

        n ->
          Logger.warning(
            "[Loopyard] marked #{n} workspace(s) as setup-failed on boot (interrupted)"
          )
      end
    end)

    # EAGERLY LOAD every app module before replaying agent logs. The log
    # decoder uses `binary_to_term(:safe)`, which REJECTS any record holding
    # an atom not yet in the atom table — and under the VM's lazy module
    # loading, early boot hasn't loaded the modules whose atoms the rich
    # `{:agent, …}` records carry (:workstation_identity, :prompt_hash, …).
    # Those records then silently decoded to :error and were skipped while
    # the simple `{:msg, …}` records survived — producing identity-less
    # agents in ETS, which broke autostart, resume, and the UI fleet-wide.
    # Loading all modules makes the decoder's "every persisted atom is
    # module-defined and pre-exists" assumption actually TRUE.
    safe_restore("EagerModules", fn ->
      {:ok, mods} = :application.get_key(:loopyard, :modules)
      Enum.each(mods, &Code.ensure_loaded/1)
    end)

    # Pre-populate agent ETS from all workspace agent logs so agents
    # are visible immediately on boot — not lazily on first page visit.
    restore_all_agents()

    # Bring back the last working state: auto-start workspaces that were used
    # (have restored agents) but whose work container is stopped, so a restart
    # doesn't leave you clicking Start on crashed agents in dead workspaces.
    # Async + best-effort so container starts never block boot. (#52)
    safe_restore("Workspace.Autostart", fn -> autostart_used_workspaces() end)

    # Scan the saga journal for incomplete sagas (BEAM crashed
    # mid-saga last run) and dispatch each per its declared
    # on_resume strategy — :rollback auto-reverts, :manual surfaces
    # on /system/sagas for the operator. Non-blocking: rollback
    # tasks are spawned under Loopyard.TaskSupervisor. Must run
    # AFTER TaskSupervisor starts (part of the child list above).
    # Move #9.
    safe_restore("Saga.Journal", fn ->
      case Loopyard.Saga.Journal.resume_all_on_boot() do
        %{incomplete: 0} ->
          :ok

        %{incomplete: n} = summary ->
          Logger.warning("[Loopyard] found #{n} incomplete saga(s) on boot: #{inspect(summary)}")
      end
    end)

    port = Application.get_env(:loopyard, LoopyardWeb.Endpoint)[:http][:port] || 4000
    IO.puts("\n  Launch from any project directory:")
    IO.puts("  open \"http://localhost:#{port}/launch/#{secret}?path=$(pwd)\"\n")

    result
  end

  defp safe_restore(name, fun) do
    fun.()
  rescue
    e ->
      Logger.warning(
        "[Loopyard] #{name} restore failed: #{Exception.message(e)} — app continuing degraded"
      )
  catch
    :exit, reason ->
      Logger.warning(
        "[Loopyard] #{name} restore failed (exit: #{inspect(reason)}) — app continuing degraded"
      )
  end

  @impl true
  def config_change(changed, _new, removed) do
    LoopyardWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # Replay every workspace's agent log into ETS at boot so agents are
  # visible immediately. Without this, agents only appear after someone
  # visits the workspace page (prime_agents_from_log in LiveView mount).
  defp restore_all_agents do
    workspaces = :ets.tab2list(:workspace_registry) |> Enum.map(fn {_id, w} -> w end)

    count =
      Enum.reduce(workspaces, 0, fn ws, acc ->
        # Skip workspaces still in setup — their containers aren't ready
        # and replaying agent logs would start agents that can't exec.
        # Legacy workspaces (no :setup key) predate the saga and are safe
        # to restore.
        setup_phase = get_in(ws, [:setup, :phase])

        if setup_phase != nil and setup_phase != :ready do
          acc
        else
          restore_workspace_agents(ws, acc)
        end
      end)

    if count > 0 do
      Logger.info("[Loopyard] Restored #{count} agent(s) from logs on boot")
    end
  rescue
    e ->
      Logger.warning("[Loopyard] restore_all_agents failed: #{Exception.message(e)}")
  end

  defp restore_workspace_agents(ws, acc) do
    ws_id = ws[:id]
    log_path = Loopyard.ChatAgent.Persistence.log_path(ws_id)

    if log_path && File.exists?(log_path) do
      case Loopyard.AgentLog.replay(log_path: log_path, version: 1, ets_table: :chat_agents) do
        {:ok, agents} when map_size(agents) > 0 ->
          acc + map_size(agents)

        _ ->
          acc
      end
    else
      acc
    end
  end

  # Auto-start the workspaces that were in use, so a server restart restores
  # the last working state instead of dropping you on crashed agents in
  # powered-down workspaces. "In use" = has restored agents. We only start a
  # workspace whose work container ALREADY EXISTS but is STOPPED — never build
  # or create a fresh one on boot. Each start runs in its own supervised Task
  # so one slow/failing start neither blocks boot nor the others. (#52)
  defp autostart_used_workspaces do
    if Application.get_env(:loopyard, :autostart_workspaces_on_boot, true) do
      used_workspace_ids()
      |> Enum.each(fn ws_id ->
        ws = Loopyard.WorkspaceRegistry.get_workspace(ws_id)

        cond do
          is_nil(ws) or not ready_workspace?(ws) ->
            :ok

          # Container ALREADY RUNNING: the workspace group (ServiceManager /
          # AgentSupervisor / agent resume) must still start — before this,
          # a running workspace stayed headless until someone happened to
          # visit its page, and agents couldn't restart ("noproc" on the
          # workspace's AgentSupervisor). Group only — no container ops.
          work_container_running?(ws_id) ->
            Task.Supervisor.start_child(Loopyard.TaskSupervisor, fn ->
              autostart_group(ws_id, ws[:path])
            end)

          # Container exists but stopped: bring the whole workspace back
          # (group + container). Never build/create fresh on boot.
          work_container_stopped?(ws_id) ->
            Task.Supervisor.start_child(Loopyard.TaskSupervisor, fn ->
              autostart_one(ws_id, ws[:path])
            end)

          true ->
            :ok
        end
      end)
    end

    :ok
  end

  # Workspace ids that have at least one restored agent (were actually used).
  defp used_workspace_ids do
    :ets.tab2list(:chat_agents)
    |> Enum.map(fn {_id, summary} -> Map.get(summary, :workspace_id) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # Same guard as restore_all_agents: skip workspaces mid-setup. Legacy
  # workspaces (no :setup key) predate the saga and are safe.
  defp ready_workspace?(ws) do
    phase = get_in(ws, [:setup, :phase])
    phase == nil or phase == :ready
  end

  # The work container exists (workspace was set up) but isn't running.
  defp work_container_stopped?(ws_id) do
    name = Loopyard.Workspace.WorkContainer.container_name(ws_id)
    Loopyard.Docker.container_exists?(name) and not Loopyard.Docker.container_running?(name)
  end

  defp work_container_running?(ws_id) do
    Loopyard.Docker.container_running?(Loopyard.Workspace.WorkContainer.container_name(ws_id))
  end

  defp autostart_one(ws_id, path) do
    if path do
      Loopyard.WorkspaceSupervisor.start_workspace(ws_id, path)
      Loopyard.Workspace.WorkContainer.ensure_up(ws_id)
      Logger.info("[Loopyard] Auto-started workspace #{ws_id} on boot")
    end
  rescue
    e ->
      Logger.warning(
        "[Loopyard] Auto-start of workspace #{ws_id} failed: #{Exception.message(e)}"
      )
  end

  # Container already running — start ONLY the supervision group; its
  # ServiceManager reconnects to the live containers and resumes agents.
  defp autostart_group(ws_id, path) do
    if path do
      Loopyard.WorkspaceSupervisor.start_workspace(ws_id, path)
      Logger.info("[Loopyard] Attached workspace group #{ws_id} to running container on boot")
    end
  rescue
    e ->
      Logger.warning(
        "[Loopyard] Group attach of workspace #{ws_id} failed: #{Exception.message(e)}"
      )
  end

  # Docker Desktop's credential helper hangs when Desktop isn't running.
  # Colima users hit this: every pull/build freezes for minutes. Detect
  # it at startup and warn loudly so they fix it before wasting time.
  defp check_docker_creds_store do
    docker_config = Path.join(System.user_home!(), ".docker/config.json")

    with {:ok, json} <- File.read(docker_config),
         {:ok, config} <- Jason.decode(json),
         "desktop" <- config["credsStore"] do
      # Check if docker-credential-desktop actually works
      case System.cmd("docker-credential-desktop", ["list"], stderr_to_stdout: true) do
        {_, 0} ->
          :ok

        _ ->
          Logger.error("""
          [Loopyard] Docker credential store is set to "desktop" but \
          docker-credential-desktop is not responding. This causes every \
          docker pull and build to hang.

          Fix: run this command to switch to the macOS keychain:

            python3 -c "import json; c=json.load(open('#{docker_config}')); c['credsStore']='osxkeychain'; json.dump(c,open('#{docker_config}','w'),indent=2)"

          Or run: /setup
          """)
      end
    else
      _ -> :ok
    end
  rescue
    _ -> :ok
  end
end
