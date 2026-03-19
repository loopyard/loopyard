defmodule BoomLooper.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    BoomLooper.ChatAgent.ensure_ets_table()
    BoomLooper.WorkspaceRegistry.ensure_ets_table()

    # Generate a launch secret for CLI onramp
    secret = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    Application.put_env(:boom_looper, :launch_secret, secret)

    children = [
      {Phoenix.PubSub, name: BoomLooper.PubSub},
      {Registry, keys: :unique, name: BoomLooper.ChatAgentRegistry},
      {Registry, keys: :unique, name: BoomLooper.ServiceManagerRegistry},
      BoomLooper.ChatAgentSupervisor,
      {DynamicSupervisor, name: BoomLooper.ServiceManagerSupervisor, strategy: :one_for_one},
      BoomLooperWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: BoomLooper.Supervisor]
    result = Supervisor.start_link(children, opts)

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
