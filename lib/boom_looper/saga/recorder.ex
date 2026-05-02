defmodule BoomLooper.Saga.Recorder do
  @moduledoc """
  Keeps a rolling record of recent `BoomLooper.Saga` runs for the
  `/system/sagas` surface.

  Move #7a in `plans/coordination-hardening.md`.

  ## How it records

  The Recorder attaches to the saga telemetry events (see
  `BoomLooper.Saga` @moduledoc) at startup. Each run is identified
  by `:saga_id` metadata; the Recorder builds up the run record in
  ETS as events arrive and marks it terminal on `:completed` /
  `:rolled_back` events.

  Telemetry handlers run in the publishing process. We keep them
  light (single ETS update per event) so a crashing handler can't
  take down the process firing the event. An explicit try/rescue
  in the handler wraps the update.

  ## Retention

  Last `@max_records` runs are kept, newest-first. Older runs are
  trimmed in a batch every time we exceed the cap. Matches the
  `Events.Tap` pattern.

  ## Public API

    * `recent/1` — list recent runs, optionally filtered by saga name
    * `summary/0` — counts: total, succeeded, rolled_back, rollback_failed
  """

  use GenServer
  require Logger

  @table :saga_recorder
  @max_records 100

  # ── Public API ──

  @doc """
  Return recent saga runs, newest-first.

  Options:

    * `:saga` — filter to a specific saga name (e.g. `:start_workspace`)
    * `:limit` — cap the number returned
  """
  def recent(opts \\ []) do
    saga = Keyword.get(opts, :saga)
    limit = Keyword.get(opts, :limit)

    records =
      case :ets.whereis(@table) do
        :undefined ->
          []

        _ ->
          :ets.tab2list(@table)
          |> Enum.map(fn {_id, record} -> record end)
          # Audit-2 LOW #11: sort newest-first on {started_at, saga_id}
          # rather than the string saga_id alone. See sort_asc/0.
          |> Enum.sort(&desc_started_at?/2)
      end

    records =
      case saga do
        nil -> records
        name -> Enum.filter(records, &(&1.saga == name))
      end

    case limit do
      nil -> records
      n when is_integer(n) -> Enum.take(records, n)
    end
  end

  @doc """
  Aggregate counts across all recent runs: `%{total, succeeded,
  rolled_back, rollback_failed, in_flight}`.
  """
  def summary do
    records =
      case :ets.whereis(@table) do
        :undefined -> []
        _ -> :ets.tab2list(@table) |> Enum.map(fn {_id, r} -> r end)
      end

    Enum.reduce(
      records,
      %{total: 0, succeeded: 0, rolled_back: 0, rollback_failed: 0, in_flight: 0},
      fn r, acc ->
        acc = %{acc | total: acc.total + 1}

        case r.status do
          :succeeded -> %{acc | succeeded: acc.succeeded + 1}
          :rolled_back -> %{acc | rolled_back: acc.rolled_back + 1}
          :rollback_failed -> %{acc | rollback_failed: acc.rollback_failed + 1}
          :in_flight -> %{acc | in_flight: acc.in_flight + 1}
          _ -> acc
        end
      end
    )
  end

  @doc false
  def table, do: @table

  # ── GenServer ──

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    # ETS table is owned by StateKeeper (audit MEDIUM #10). Previously
    # this module called `:ets.new/2` directly, which meant a Recorder
    # crash destroyed the table and every recorded saga was lost.
    # StateKeeper-owned means the table survives any number of
    # Recorder restarts.
    BoomLooper.StateKeeper.ensure_tables!()
    attach_handlers()

    {:ok, %{}}
  end

  @impl true
  def terminate(_reason, _state) do
    detach_handlers()
    :ok
  end

  # Catchalls — Recorder is a GenServer with zero user-facing
  # cast/call/info handlers (it's a passive telemetry consumer). Any
  # stray OTP message (monitor DOWN, node up/down, test helper junk)
  # would crash the GenServer with a FunctionClauseError and take
  # its ETS history with it. These catchalls absorb stray messages
  # via [:boom_looper, :actor, :unknown_message] telemetry.
  @impl true
  def handle_info(msg, state) do
    Logger.warning("[Saga.Recorder] unhandled info: #{inspect(msg, limit: 200)}")

    :telemetry.execute(
      [:boom_looper, :actor, :unknown_message],
      %{count: 1},
      %{actor: __MODULE__, kind: :info, msg: inspect(msg, limit: 200)}
    )

    {:noreply, state}
  end

  @impl true
  def handle_cast(msg, state) do
    Logger.warning("[Saga.Recorder] unhandled cast: #{inspect(msg, limit: 200)}")

    :telemetry.execute(
      [:boom_looper, :actor, :unknown_message],
      %{count: 1},
      %{actor: __MODULE__, kind: :cast, msg: inspect(msg, limit: 200)}
    )

    {:noreply, state}
  end

  @impl true
  def handle_call(msg, _from, state) do
    Logger.warning("[Saga.Recorder] unhandled call: #{inspect(msg, limit: 200)}")

    :telemetry.execute(
      [:boom_looper, :actor, :unknown_message],
      %{count: 1},
      %{actor: __MODULE__, kind: :call, msg: inspect(msg, limit: 200)}
    )

    {:reply, {:error, :unknown_call}, state}
  end

  # ── Telemetry handlers ──

  @handler_id {__MODULE__, :handler}

  defp attach_handlers do
    :telemetry.attach_many(
      @handler_id,
      [
        [:boom_looper, :saga, :started],
        [:boom_looper, :saga, :step_succeeded],
        [:boom_looper, :saga, :step_failed],
        [:boom_looper, :saga, :step_rolled_back],
        [:boom_looper, :saga, :rolled_back],
        [:boom_looper, :saga, :rollback_failed],
        [:boom_looper, :saga, :completed]
      ],
      &__MODULE__.handle_event/4,
      nil
    )
  end

  defp detach_handlers do
    :telemetry.detach(@handler_id)
  end

  @doc false
  def handle_event(event, measurements, metadata, _config) do
    try do
      do_handle(event, measurements, metadata)
    rescue
      e ->
        Logger.warning("[Saga.Recorder] handler crashed: #{Exception.message(e)}")
    end
  end

  defp do_handle([:boom_looper, :saga, :started], measurements, meta) do
    %{saga_id: id, saga: saga} = meta

    record = %{
      saga_id: id,
      saga: saga,
      status: :in_flight,
      started_at: DateTime.utc_now(),
      finished_at: nil,
      step_count: Map.get(measurements, :step_count, 0),
      completed_steps: [],
      failed_step: nil,
      failure_reason: nil,
      rolled_back_steps: [],
      failed_rollbacks: [],
      metadata: Map.drop(meta, [:saga, :saga_id])
    }

    :ets.insert(@table, {id, record})
    maybe_trim()
  end

  defp do_handle([:boom_looper, :saga, :step_succeeded], measurements, meta) do
    update(meta, fn record ->
      step_record = %{
        name: meta.step,
        duration_us: Map.get(measurements, :duration_us, 0),
        status: :succeeded
      }

      %{record | completed_steps: record.completed_steps ++ [step_record]}
    end)
  end

  defp do_handle([:boom_looper, :saga, :step_failed], measurements, meta) do
    update(meta, fn record ->
      step_record = %{
        name: meta.step,
        duration_us: Map.get(measurements, :duration_us, 0),
        status: :failed,
        reason: Map.get(meta, :reason)
      }

      %{
        record
        | completed_steps: record.completed_steps ++ [step_record],
          failed_step: meta.step,
          failure_reason: Map.get(meta, :reason)
      }
    end)
  end

  defp do_handle([:boom_looper, :saga, :step_rolled_back], _measurements, meta) do
    update(meta, fn record ->
      %{record | rolled_back_steps: record.rolled_back_steps ++ [meta.step]}
    end)
  end

  defp do_handle([:boom_looper, :saga, :rollback_failed], _measurements, meta) do
    update(meta, fn record ->
      %{
        record
        | failed_rollbacks: record.failed_rollbacks ++ [{meta.step, Map.get(meta, :reason)}]
      }
    end)
  end

  defp do_handle([:boom_looper, :saga, :rolled_back], _measurements, meta) do
    update(meta, fn record ->
      status =
        if record.failed_rollbacks == [] do
          :rolled_back
        else
          :rollback_failed
        end

      %{record | status: status, finished_at: DateTime.utc_now()}
    end)
  end

  defp do_handle([:boom_looper, :saga, :completed], _measurements, meta) do
    update(meta, fn record ->
      %{record | status: :succeeded, finished_at: DateTime.utc_now()}
    end)
  end

  defp do_handle(_other, _measurements, _meta), do: :ok

  defp update(%{saga_id: id}, fun) do
    case :ets.lookup(@table, id) do
      [{^id, record}] ->
        :ets.insert(@table, {id, fun.(record)})

      [] ->
        # Dropped :started event (rare — tests starting/stopping
        # the recorder mid-run, or telemetry racing with init).
        # Ignore; we won't have the full record for this saga.
        :ok
    end
  end

  # Previously a silent `:ok`. A producer emitting a saga telemetry
  # event without `:saga_id` in metadata is a bug anywhere in the
  # chain — the recorder going mute with no signal left operators
  # with no breadcrumbs. Match the `[:boom_looper, :actor,
  # :unknown_message]` pattern used by the silent-handle_info fixes.
  defp update(meta, _fun) do
    Logger.warning(
      "[Saga.Recorder] telemetry event missing :saga_id metadata: #{inspect(meta, limit: 200)}"
    )

    :telemetry.execute(
      [:boom_looper, :actor, :unknown_message],
      %{count: 1},
      %{actor: __MODULE__, reason: :missing_saga_id, meta: inspect(meta, limit: 200)}
    )

    :ok
  end

  # Every N inserts trim down to @max_records. Batched rather than
  # per-insert for the same reason as Events.Tap — the hot path is
  # the telemetry handler, it should not linearly walk the table.
  #
  # Audit-2 LOW #11: sort on `started_at` (a DateTime with microsecond
  # precision set at `:saga_started`) rather than the string saga_id.
  # Lex sort of "#{us}-#{seq}" is chronological today because
  # `us` is a fixed 16 digits, but that's a property of the current
  # saga_id format — switching to started_at makes trim resilient
  # if the format ever changes. Saga ids fall back as a tiebreaker
  # for records that somehow arrived with the same timestamp.
  defp maybe_trim do
    info = :ets.info(@table)
    size = Keyword.get(info, :size, 0)

    if size > @max_records * 2 do
      to_delete = size - @max_records

      :ets.tab2list(@table)
      |> Enum.sort(fn {a_id, a}, {b_id, b} ->
        asc_started_at?({a.started_at, a_id}, {b.started_at, b_id})
      end)
      |> Enum.take(to_delete)
      |> Enum.each(fn {id, _} -> :ets.delete(@table, id) end)
    end

    :ok
  end

  # Oldest-first comparator for records tuple-keyed by {started_at,
  # saga_id}. DateTime comparisons use DateTime.compare/2 (string lex
  # sort would be wrong across microsecond rollovers in the far
  # future), and saga_id is a tiebreaker for records written inside
  # the same microsecond. Missing `started_at` (nil) sorts as oldest
  # so malformed records trim first.
  defp asc_started_at?({%DateTime{} = a, a_id}, {%DateTime{} = b, b_id}) do
    case DateTime.compare(a, b) do
      :lt -> true
      :gt -> false
      :eq -> a_id <= b_id
    end
  end

  defp asc_started_at?({nil, _}, {_, _}), do: true
  defp asc_started_at?({_, _}, {nil, _}), do: false

  # Newest-first comparator for records. Used by `recent/0`.
  defp desc_started_at?(a, b) do
    asc_started_at?({b.started_at, b.saga_id}, {a.started_at, a.saga_id})
  end
end
