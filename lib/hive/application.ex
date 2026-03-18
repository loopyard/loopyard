defmodule Hive.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Hive.ChatAgent.ensure_ets_table()

    children = [
      {Phoenix.PubSub, name: Hive.PubSub},
      {Registry, keys: :unique, name: Hive.ChatAgentRegistry},
      {Registry, keys: :unique, name: Hive.ServiceManagerRegistry},
      Hive.ChatAgentSupervisor,
      {DynamicSupervisor, name: Hive.ServiceManagerSupervisor, strategy: :one_for_one},
      HiveWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Hive.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    HiveWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
