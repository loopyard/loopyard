defmodule Hive.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: Hive.PubSub},
      {Registry, keys: :unique, name: Hive.AgentRegistry},
      {Registry, keys: :unique, name: Hive.ChatAgentRegistry},
      HiveWeb.Presence,
      Hive.AgentSupervisor,
      Hive.ChatAgentSupervisor,
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
