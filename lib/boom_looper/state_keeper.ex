defmodule BoomLooper.StateKeeper do
  @moduledoc """
  Long-lived GenServer that is the sole owner of all shared ETS tables.

  ETS tables die with their owner. Centralizing creation here means:

  1. One place knows every table name and its options.
  2. No races — no other code path calls `:ets.new`, so there's no
     need for `try/catch :error, :badarg` guards elsewhere.
  3. If StateKeeper dies and the supervisor restarts it, every table
     it owned is gone — any process holding a stale reference will
     crash on next access and be restarted by its own supervisor.
     That's the intended blast radius; don't hot-restore tables.

  Start this process EARLY in the application supervisor, before any
  module that reads from these tables.
  """
  use GenServer

  @tables [
    {:chat_agents, [:named_table, :public, :set]},
    {:project_registry, [:named_table, :public, :set]},
    {:workspace_registry, [:named_table, :public, :set]},
    {:event_log, [:named_table, :public, :ordered_set]},
    {:service_status_cache, [:named_table, :public, :set, {:read_concurrency, true}]},
    {:docker_observer, [:named_table, :public, :set, {:read_concurrency, true}]},
    {:boom_looper_evals, [:named_table, :public, :set]},
    # BoomLooper.PortRegistry entries keyed by {workspace_id, service, container_port}.
    # Writes serialize through the PortRegistry GenServer; reads go direct.
    {:port_registry, [:named_table, :public, :set, {:read_concurrency, true}]},
    # Ring buffer for BoomLooper.Events.Tap — every broadcast on every
    # known topic. ordered_set keyed by a monotonic counter so the
    # newest records come out with a single :ets.select_reverse.
    # Plan: Move #7.
    {:events_tap, [:named_table, :public, :ordered_set, {:read_concurrency, true}]},
    # BoomLooper.Resources.Janitor — tracked OS/OTP resources keyed
    # by {kind, id}. Reads go direct for list_for_owner / all; writes
    # serialize through the Janitor GenServer so the owner-index and
    # monitor refs stay consistent. Plan: Move #7b.
    {:resource_registry, [:named_table, :public, :set, {:read_concurrency, true}]},
    # BoomLooper.ChatAgent.RestartController crash history keyed by
    # {workspace_id, agent_id}. Lives here so that when WorkspaceGroup
    # restarts the RestartController (via :one_for_all on any sibling
    # crash), the crash counters survive — otherwise quarantine gets
    # reset and an agent that was 4-of-5 crashes resets to 0-of-5.
    # Move #10 bug fix (audit item HIGH #3).
    {:restart_controller_history, [:named_table, :public, :set, {:read_concurrency, true}]},
    # BoomLooper.Saga.Recorder — last 100 saga run records keyed by
    # saga_id. Previously created in Recorder.init/1 directly, which
    # violated the "StateKeeper is the sole ETS owner" invariant and
    # meant a Recorder crash dropped every recorded saga. Owned here
    # now so recovery is trivial. Audit item MEDIUM #10.
    {:saga_recorder, [:named_table, :public, :set, {:read_concurrency, true}]}
  ]

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Idempotently ensure all tables exist. Safe to call from tests that
  start this module manually. In a running application the tables are
  created in `init/1` and this is a no-op.
  """
  def ensure_tables! do
    Enum.each(@tables, fn {name, opts} ->
      if :ets.whereis(name) == :undefined do
        :ets.new(name, opts)
      end
    end)
    :ok
  end

  @impl true
  def init(:ok) do
    ensure_tables!()
    BoomLooper.EventLog.info("system", "BoomLooper started")
    {:ok, %{}}
  end

  def put_eval(name, info), do: :ets.insert(:boom_looper_evals, {name, info})

  def get_eval(name) do
    case :ets.lookup(:boom_looper_evals, name) do
      [{^name, info}] -> info
      _ -> nil
    end
  end

  def list_evals, do: :ets.tab2list(:boom_looper_evals)
end
