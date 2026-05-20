defmodule Loopyard.Application do
  @moduledoc false
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    # Generate a launch secret for CLI onramp
    secret = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    Application.put_env(:loopyard, :launch_secret, secret)

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

      # Generative ambient audio engine. Singleton GenServer that
      # renders PCM chunks and broadcasts via Events.Ambient. Sleeps
      # until a client tells it to play. See
      # plans/ambient-soundtrack.md.
      Loopyard.Ambient.Engine,

      # Saga recorder — attaches to Loopyard.Saga telemetry and
      # keeps the last 100 runs in ETS for /system/sagas. Move #7a.
      # Must start before the first saga runs (which happens on any
      # workspace start / agent boot, i.e. well after app boot).
      Loopyard.Saga.Recorder,

      # Periodic reconciler: diffs :chat_agents ETS against
      # ChatAgentRegistry every 30s and corrects drift where
      # Registry is authoritative. Must start after StateKeeper
      # (reads ETS) and ChatAgentRegistry (looks up pids).
      Loopyard.Agent.Reconciler,

      # --- Web layer (can restart independently) ---
      LoopyardWeb.Endpoint
    ]

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
    # ServiceManager will reconnect to any running containers
    Loopyard.ProjectRegistry.restore()

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

    # Pre-populate agent ETS from all workspace agent logs so agents
    # are visible immediately on boot — not lazily on first page visit.
    restore_all_agents()

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
