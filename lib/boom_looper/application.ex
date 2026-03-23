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
      # StateKeeper owns ETS tables — must start first, lives longest
      BoomLooper.StateKeeper,
      {Phoenix.PubSub, name: BoomLooper.PubSub},
      {Registry, keys: :unique, name: BoomLooper.ChatAgentRegistry},
      {Registry, keys: :unique, name: BoomLooper.ServiceManagerRegistry},
      {Registry, keys: :unique, name: BoomLooper.WorkspaceRegistry},
      {Registry, keys: :unique, name: BoomLooper.WorkspaceAgentRegistry},
      {Registry, keys: :unique, name: BoomLooper.TerminalRegistry},
      {DynamicSupervisor, name: BoomLooper.TerminalSupervisor, strategy: :one_for_one},
      BoomLooper.WorkspaceSupervisor,

      # --- Web layer (can restart independently) ---
      BoomLooperWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: BoomLooper.Supervisor]
    result = Supervisor.start_link(children, opts)

    # Start SSH if enabled via /connect
    if Application.get_env(:boom_looper, :ssh_enabled, false) do
      case BoomLooper.SSHServer.start_link() do
        {:ok, _} -> :ok
        {:error, reason} -> Logger.warning("[SSHServer] Not started: #{inspect(reason)}")
      end
    end

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
