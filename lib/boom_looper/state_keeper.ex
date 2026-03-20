defmodule BoomLooper.StateKeeper do
  @moduledoc """
  Long-lived GenServer that owns ETS tables. Survives code reloads.
  ETS tables die with their owner — this process ensures they outlive
  hot reloads of web/agent modules.
  """
  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    # Create ETS tables owned by this process
    # They survive as long as this GenServer lives
    BoomLooper.ChatAgent.ensure_ets_table()
    BoomLooper.ProjectRegistry.ensure_ets_tables()
    {:ok, %{}}
  end
end
