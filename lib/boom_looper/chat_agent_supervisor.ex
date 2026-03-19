defmodule BoomLooper.ChatAgentSupervisor do
  @moduledoc """
  DynamicSupervisor for chat-mode Claude agents.
  """
  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_agent(opts) do
    DynamicSupervisor.start_child(__MODULE__, {BoomLooper.ChatAgent, opts})
  end
end
