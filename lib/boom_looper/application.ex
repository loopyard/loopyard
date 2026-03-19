defmodule BoomLooper.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    BoomLooper.ChatAgent.ensure_ets_table()
    BoomLooper.WorkspaceRegistry.ensure_ets_table()

    children = [
      {Phoenix.PubSub, name: BoomLooper.PubSub},
      {Registry, keys: :unique, name: BoomLooper.ChatAgentRegistry},
      {Registry, keys: :unique, name: BoomLooper.ServiceManagerRegistry},
      BoomLooper.ChatAgentSupervisor,
      {DynamicSupervisor, name: BoomLooper.ServiceManagerSupervisor, strategy: :one_for_one},
      BoomLooperWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: BoomLooper.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    BoomLooperWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
