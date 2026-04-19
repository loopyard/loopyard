defmodule BoomLooper.Application do
  @moduledoc false
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    # Generate a launch secret for CLI onramp
    secret = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    Application.put_env(:boom_looper, :launch_secret, secret)

    # Register ChatAgent.summary/1 with its StateMachine so the pure
    # step/2 function can build ETS entries without a circular compile
    # dependency. See ChatAgent.StateMachine module doc for the
    # rationale (Move #1 of plans/coordination-hardening.md).
    BoomLooper.ChatAgent.StateMachine.configure_summary(
      &BoomLooper.ChatAgent.summary_public/1
    )

    children = [
      # --- Infrastructure layer (survives web reloads) ---
      BoomLooper.LogBuffer,
      BoomLooper.IExSession,
      # StateKeeper owns ETS tables — must start first, lives longest
      BoomLooper.StateKeeper,
      {Phoenix.PubSub, name: BoomLooper.PubSub},
      {Registry, keys: :unique, name: BoomLooper.ChatAgentRegistry},
      {Registry, keys: :unique, name: BoomLooper.ServiceManagerRegistry},
      {Registry, keys: :unique, name: BoomLooper.WorkspaceRegistry},
      {Registry, keys: :unique, name: BoomLooper.WorkspaceAgentRegistry},
      {Registry, keys: :unique, name: BoomLooper.SyncMonitorRegistry},
      {Registry, keys: :unique, name: BoomLooper.TerminalRegistry},
      {DynamicSupervisor, name: BoomLooper.TerminalSupervisor, strategy: :one_for_one},
      {Task.Supervisor, name: BoomLooper.TaskSupervisor},
      BoomLooper.WorkspaceSupervisor,
      BoomLooper.PortRegistry,
      {Registry, keys: :unique, name: BoomLooper.PortExposerRegistry},
      {DynamicSupervisor, name: BoomLooper.PortExposerSupervisor, strategy: :one_for_one},
      BoomLooper.SSHServer,
      BoomLooper.HostExposer,

      # Docker event-driven cache — starts the event stream + initial
      # snapshot so LiveViews can read container/volume state from ETS
      # instantly on mount. Must start after PubSub (broadcasts) and
      # before Endpoint (first LiveView mount).
      BoomLooper.Docker.Observer,

      # --- Web layer (can restart independently) ---
      BoomLooperWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: BoomLooper.Supervisor]
    result = Supervisor.start_link(children, opts)

    # Attach the slow-mount logger so we get a loud warning if any
    # LiveView callback exceeds 500ms in production. The :timer.tc
    # mount tests catch this locally; this is the prod safety net.
    BoomLooperWeb.SlowMountLogger.attach()

    # EventLog handler captures boom_looper-tagged Logger events into ETS
    # EventLog now writes directly to ETS AND emits to Logger

    # Warn loudly if mutagen isn't installed — Local workspaces need it for
    # host ↔ volume sync. GitHub workspaces still work without it.
    unless BoomLooper.Source.Local.Mutagen.installed?() do
      Logger.warning(
        "[BoomLooper] mutagen not found on $PATH. Local workspaces will not sync " <>
          "with the host. Install it with: brew bundle install"
      )
    end

    # Detect Docker credential store misconfiguration. If credsStore is
    # set to "desktop" but Docker Desktop isn't running (colima users),
    # every docker pull/build hangs waiting for docker-credential-desktop.
    check_docker_creds_store()

    # Restore persisted projects from ~/.boomlooper/projects.json
    # ServiceManager will reconnect to any running containers
    BoomLooper.ProjectRegistry.restore()

    # Load persisted port assignments from ~/.boomlooper/ports.json,
    # or seed from legacy sticky port maps on first boot. Must run
    # AFTER ProjectRegistry.restore/0 so the migration path can see
    # every known workspace.
    BoomLooper.PortRegistry.restore()

    # Restore host exposure setting from ~/.boomlooper/host_exposure.json.
    # If the operator had exposed the endpoint last session, re-bind to
    # 0.0.0.0 by restarting the endpoint. Must run AFTER Endpoint starts.
    BoomLooper.HostExposer.restore()

    port = Application.get_env(:boom_looper, BoomLooperWeb.Endpoint)[:http][:port] || 4000
    IO.puts("\n  Launch from any project directory:")
    IO.puts("  open \"http://localhost:#{port}/launch/#{secret}?path=$(pwd)\"\n")

    result
  end

  @impl true
  def config_change(changed, _new, removed) do
    BoomLooperWeb.Endpoint.config_change(changed, removed)
    :ok
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
          [BoomLooper] Docker credential store is set to "desktop" but \
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
