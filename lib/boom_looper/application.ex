defmodule BoomLooper.Application do
  @moduledoc false
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    # Generate a launch secret for CLI onramp
    secret = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    Application.put_env(:boom_looper, :launch_secret, secret)

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
      BoomLooper.SSHServer,

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

    # Warn loudly if mutagen isn't installed — Local workspaces need it for
    # host ↔ volume sync. GitHub workspaces still work without it.
    unless BoomLooper.Source.Local.Mutagen.installed?() do
      Logger.warning(
        "[BoomLooper] mutagen not found on $PATH. Local workspaces will not sync " <>
          "with the host. Install it with: brew bundle install"
      )
    end

    # Restore persisted projects from ~/.boomlooper/projects.json
    # ServiceManager will reconnect to any running containers
    BoomLooper.ProjectRegistry.restore()

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
end
