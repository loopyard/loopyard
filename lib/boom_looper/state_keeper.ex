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

  @eval_table :boom_looper_evals

  @impl true
  def init(:ok) do
    BoomLooper.ChatAgent.ensure_ets_table()
    BoomLooper.ProjectRegistry.ensure_ets_tables()
    BoomLooper.EventLog.ensure_ets_table()
    :ets.new(@eval_table, [:named_table, :public, :set])
    BoomLooper.EventLog.info("system", "BoomLooper started")
    {:ok, %{}}
  end

  def put_eval(name, info), do: :ets.insert(@eval_table, {name, info})

  def get_eval(name) do
    case :ets.lookup(@eval_table, name) do
      [{^name, info}] -> info
      _ -> nil
    end
  end

  def list_evals, do: :ets.tab2list(@eval_table)
end
