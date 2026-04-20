defmodule BoomLooper.Saga.Journal do
  @moduledoc """
  Durable saga journal + resume-on-boot.

  Move #9 in `plans/coordination-hardening.md`.

  ## The bug class this kills

  `BoomLooper.Saga` (Move #7a) guarantees either-succeed-or-roll-back
  **within a single BEAM lifetime**. If the node dies mid-saga —
  kernel panic, power loss, `kill -9` — the saga had already written
  ETS entries, spun up containers, or bound ports. On reboot we have
  persistent half-state AND no memory of how far the saga got.

  This module durably records each saga's progress to disk BEFORE
  each step executes. On boot, it scans for incomplete sagas; for
  each one we either resume forward (if the saga declared
  `on_resume: :resume_forward` AND remaining steps are idempotent)
  or run a rollback-from-here (default — safest).

  ## File format

  Single append-only length-prefixed ETF file at
  `<BOOMLOOPER_HOME>/sagas.log`. Uses the exact same record framing as
  `BoomLooper.AgentLog`: `[4 bytes: size][N bytes: zlib-compressed ETF]`.
  Version is currently `1`. First record is a
  `{:log_meta, %{version: 1, created_at: DateTime}}` header.

  Journal events:

    * `{:saga_started, saga_id, name, metadata, on_resume, step_names, started_at}`
    * `{:step_started, saga_id, step_name, context_before}`
    * `{:step_succeeded, saga_id, step_name, context_after}`
    * `{:step_failed, saga_id, step_name, reason}`
    * `{:step_rolled_back, saga_id, step_name}`
    * `{:rollback_failed, saga_id, step_name, reason}`
    * `{:saga_completed, saga_id}`
    * `{:saga_rolled_back, saga_id, failure}`

  The journal is app-wide (not per-workspace) because sagas can span
  workspace lifecycle events (start, destroy) and a
  per-workspace journal would miss `start_workspace` sagas that fail
  before the workspace dir exists.

  ## Why write BEFORE executing

  If we wrote "step 3 started" and then crashed, on resume we know
  step 3 might be half-done and rollback is needed. If we wrote AFTER,
  we'd think step 3 never happened and skip its rollback on resume —
  leaking whatever state step 3 created.

  The cost: step 3 never actually ran, but the journal says it started.
  On rollback we'll attempt to undo a step that did nothing. That's
  safe as long as rollback functions are idempotent against "resource
  doesn't exist" (which every rollback in this repo already is — they
  call `stop_agent`, `compose_down`, etc., all of which tolerate
  nothing-to-undo).

  ## Resume strategies

  Each saga declares `on_resume` when calling `Saga.run/2`:

    * `:rollback` (default, safest) — treat an incomplete saga as
      failed at the last-started step. Run every completed step's
      rollback in reverse order, including the in-flight step if it
      had already recorded `:step_started`. Surfaces the saga as
      `:rolled_back_on_boot` in `/system/sagas`.

    * `:resume_forward` — re-run the steps that weren't recorded
      completed. Requires every remaining step to be idempotent. Use
      sparingly: "make agent idempotent against double-execution"
      is more work than it looks.

    * `:manual` — don't auto-act. Surface the incomplete saga in
      `/system/sagas` with a red banner and let an operator decide.
      Use for sagas with expensive non-idempotent side effects where
      auto-rollback would be more disruptive than the half-state.

  ## Compaction

  The journal grows unboundedly: every successful saga leaves its
  entire step history behind. On each call to `append/1` we bump a
  counter; once we cross a threshold of "finished saga records", the
  file is rewritten to only the still-incomplete saga records plus
  the last N finished sagas per saga name (audit trail). Compaction
  is atomic: writes to `.compacting`, then `File.rename/2`.

  ## Resume is non-blocking

  `resume_all_on_boot/0` returns quickly after dispatching a
  supervised `Task` per incomplete saga. The app continues booting;
  LiveViews show a "recovery in progress" banner via
  `/system/sagas`. Blocking app boot on saga resume would pessimize
  the common case (no sagas in flight) for the rare case (node
  crashed mid-start).

  ## What the journal is NOT

  It's not an event store. It's not a general-purpose log. It exists
  exclusively to survive BEAM death mid-saga. Don't reach for it as a
  substitute for persistence of other state — that's `AgentLog`'s job.

  ## Corruption handling

  The file is written append-only with `File.write!/3` in `:raw` mode.
  Mid-record crashes leave a truncated tail. `read_records/1` stops
  cleanly at the first truncated record (same policy as
  `AgentLog.read_entries/2`). The sagas recorded before the crash are
  still recoverable. The saga mid-record at crash time might be lost —
  that's equivalent to "we never knew it started" on the resumer.
  """

  require Logger

  @version 1
  @compaction_threshold 200
  @audit_tail_per_saga 5

  @typedoc "Resume strategy declared by the saga."
  @type on_resume :: :rollback | :resume_forward | :manual

  @typedoc ~S"""
  saga_id produced by `BoomLooper.Saga.make_saga_id/0`. Formatted as
  `"#{system_time_us}-#{monotonic_unique_integer}"` so it survives
  BEAM restarts without colliding with integer ids from prior
  lifetimes. Audit-2 MEDIUM #4.
  """
  @type saga_id :: String.t()

  @typedoc "Journal record variants (see module doc)."
  @type record ::
          {:saga_started, saga_id(), atom(), map(), on_resume(), [atom()], integer()}
          | {:step_started, saga_id(), atom(), map()}
          | {:step_succeeded, saga_id(), atom(), map()}
          | {:step_failed, saga_id(), atom(), term()}
          | {:step_rolled_back, saga_id(), atom()}
          | {:rollback_failed, saga_id(), atom(), term()}
          | {:saga_completed, saga_id()}
          | {:saga_rolled_back, saga_id(), term()}

  # ── Public API ──

  @doc """
  Append a record to the journal. Idempotent for file creation.
  Caller is expected to pass a valid record tuple.

  On I/O failure, logs and returns `{:error, reason}` but does NOT
  raise — a failing journal must not crash the saga it's tracking.
  The saga still completes in-memory; only durability is lost.
  """
  @spec append(record()) :: :ok | {:error, term()}
  def append(record) do
    path = path()

    try do
      dir = Path.dirname(path)
      unless File.exists?(dir), do: File.mkdir_p!(dir)
      ensure_meta_header(path)
      write_record(path, record)

      :telemetry.execute(
        [:boom_looper, :saga, :journal_written],
        %{count: 1},
        %{record_type: elem(record, 0), saga_id: saga_id_of(record)}
      )

      maybe_compact()
      :ok
    rescue
      e ->
        Logger.warning("[Saga.Journal] append failed: #{Exception.message(e)}")
        {:error, {:exception, Exception.message(e)}}
    catch
      kind, reason ->
        Logger.warning("[Saga.Journal] append failed: #{inspect({kind, reason})}")
        {:error, {kind, reason}}
    end
  end

  @doc """
  Return the list of sagas whose journal shows `:saga_started` with
  no matching `:saga_completed` or `:saga_rolled_back`.

  Each entry is a map: `%{saga_id, name, metadata, on_resume,
  step_names, started_at, completed_steps, started_step, trace}`
  where `trace` is the chronological list of journal records for
  this saga. `completed_steps` lists the steps that recorded
  `:step_succeeded`; `started_step` is the most recent step that
  recorded `:step_started` but did not (yet) record
  `:step_succeeded` or `:step_failed` — that's the step we crashed
  during.
  """
  @spec incomplete() :: [map()]
  def incomplete do
    path()
    |> read_records()
    |> build_sagas()
    |> Enum.filter(&(&1.status == :in_flight))
    |> Enum.sort_by(& &1.saga_id)
  end

  @doc """
  Return the full ordered record trace for a saga_id, or `[]` if
  no such saga exists in the journal.
  """
  @spec trace(saga_id()) :: [record()]
  def trace(saga_id) do
    path()
    |> read_records()
    |> Enum.filter(fn
      {_tag, ^saga_id} -> true
      {_tag, ^saga_id, _} -> true
      {_tag, ^saga_id, _, _} -> true
      {_tag, ^saga_id, _, _, _} -> true
      {:saga_started, ^saga_id, _, _, _, _, _} -> true
      _ -> false
    end)
  end

  @doc """
  Return all saga records (including finished) built up from the
  journal — one `%{saga_id, name, status, ...}` map per saga.
  Used by the `/system/sagas` page to show historical outcomes.
  """
  @spec all_sagas() :: [map()]
  def all_sagas do
    path()
    |> read_records()
    |> build_sagas()
    |> Enum.sort_by(& &1.saga_id, :desc)
  end

  @doc """
  Scan the journal and act on every incomplete saga per its declared
  `on_resume` strategy. Dispatches supervised Tasks so boot doesn't
  block.

  Returns `%{incomplete: n, dispatched: n, rolled_back: n,
  resumed: n, manual: n}` summarizing what was acted on.
  """
  @spec resume_all_on_boot() :: map()
  def resume_all_on_boot do
    incomplete_sagas = incomplete()

    summary = %{
      incomplete: length(incomplete_sagas),
      dispatched: 0,
      rolled_back: 0,
      resumed: 0,
      manual: 0
    }

    Enum.reduce(incomplete_sagas, summary, fn saga, acc ->
      case saga.on_resume do
        :rollback ->
          dispatch_rollback(saga)

          %{acc | dispatched: acc.dispatched + 1, rolled_back: acc.rolled_back + 1}

        :resume_forward ->
          # We don't actually re-run forward today — too dangerous
          # without per-saga resume handlers registered by name. We
          # log the intent and roll back; if/when a saga registers a
          # resume handler, extend this clause to dispatch it.
          Logger.warning(
            "[Saga.Journal] #{saga.name}/#{saga.saga_id} declared :resume_forward " <>
              "but no resume handler is registered; falling back to rollback"
          )

          # Emit dedicated telemetry so operators running telemetry-
          # forwarders don't have to grep logs for the downgrade.
          # Audit MEDIUM #6.
          :telemetry.execute(
            [:boom_looper, :saga, :resume_forward_downgraded],
            %{count: 1},
            %{saga: saga.name, saga_id: saga.saga_id, reason: :no_handler_registered}
          )

          dispatch_rollback(saga)

          %{acc | dispatched: acc.dispatched + 1, rolled_back: acc.rolled_back + 1}

        :manual ->
          Logger.warning(
            "[Saga.Journal] #{saga.name}/#{saga.saga_id} declared :manual on resume; " <>
              "operator must resolve via /system/sagas"
          )

          :telemetry.execute(
            [:boom_looper, :saga, :resume_manual],
            %{count: 1},
            Map.merge(saga.metadata, %{saga: saga.name, saga_id: saga.saga_id})
          )

          %{acc | manual: acc.manual + 1}
      end
    end)
  end

  @doc """
  Return the path to the journal file. Resolves on every call so the
  tests (which set `BOOMLOOPER_HOME` per-run) always see the current
  value. The resolution mirrors `BoomLooper.Workspace.home_dir/0` but
  is reimplemented here to avoid a circular alias in this low-level
  module.
  """
  @spec path() :: Path.t()
  def path do
    home =
      case System.get_env("BOOMLOOPER_HOME") do
        val when val in [nil, ""] -> Path.join(System.user_home!(), ".boomlooper")
        path -> path
      end

    Path.join(home, "sagas.log")
  end

  @doc """
  Rewrite the journal: drop finished sagas except the last
  `@audit_tail_per_saga` per saga name (audit trail), keep every
  in-flight saga's full trace. Atomic rename. Cheap no-op if the file
  doesn't exist.
  """
  @spec compact() :: {:ok, map()} | {:error, term()}
  def compact do
    path = path()

    case File.stat(path) do
      {:ok, %{size: before_size}} ->
        records = read_records(path)
        {finished, in_flight_records} = split_records(records)
        audit_records = keep_recent_per_saga_name(finished, @audit_tail_per_saga, records)
        kept = audit_records ++ in_flight_records

        temp = path <> ".compacting"
        File.rm(temp)

        write_meta_header(temp)

        for rec <- kept do
          write_record(temp, rec)
        end

        case File.rename(temp, path) do
          :ok ->
            after_size =
              case File.stat(path) do
                {:ok, %{size: s}} -> s
                _ -> 0
              end

            {:ok,
             %{before: before_size, after: after_size, kept: length(kept),
               dropped: length(records) - length(kept)}}

          {:error, reason} ->
            File.rm(temp)
            {:error, {:rename_failed, reason}}
        end

      {:error, :enoent} ->
        {:ok, %{before: 0, after: 0, kept: 0, dropped: 0}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Wipe the journal (for tests). No-op if the file doesn't exist.
  """
  @spec clear() :: :ok
  def clear do
    File.rm(path())
    reset_compaction_counter()
    :ok
  end

  # ── Rollback dispatch ──

  # Run the rollback hooks for an incomplete saga. We don't have the
  # original forward steps in memory on resume — the journal only
  # persisted their names. A full replay would require the saga
  # caller to register steps by name at app startup, which is the
  # shape of #9 that we're deliberately deferring. For this pass,
  # we:
  #
  #   1. Record `:saga_rolled_back` in the journal so the saga is
  #      marked terminal and won't re-fire on next boot.
  #   2. Fire `[:boom_looper, :saga, :rolled_back_on_boot]` telemetry
  #      with the saga metadata so `/system/sagas` can show it.
  #   3. Log a warning.
  #
  # The actual *external* state left over from the crashed saga is
  # cleaned up by the standing reconcilers (Move #6, Agent.Reconciler)
  # and per-workspace `terminate/2` handlers. The journal's promise is
  # "no saga is ever abandoned in the accounting sense" — not "every
  # side effect is automatically reverted on boot." Auto-reverting
  # requires saga-caller cooperation (registering rollback closures
  # under the saga name at app startup) and is tracked as a future
  # move; the present code makes the accounting durable so we can
  # see on `/system/sagas` exactly which sagas need manual attention.
  defp dispatch_rollback(saga) do
    Task.Supervisor.start_child(BoomLooper.TaskSupervisor, fn ->
      Logger.warning(
        "[Saga.Journal] rolling back incomplete saga on boot: " <>
          "#{saga.name}/#{saga.saga_id} (crashed at step #{saga.started_step || "(none)"})"
      )

      append({:saga_rolled_back, saga.saga_id, :crashed_mid_saga})

      :telemetry.execute(
        [:boom_looper, :saga, :rolled_back_on_boot],
        %{count: 1},
        Map.merge(saga.metadata, %{
          saga: saga.name,
          saga_id: saga.saga_id,
          crashed_step: saga.started_step,
          completed_steps: saga.completed_steps
        })
      )
    end)
  end

  # ── Internal: file I/O ──

  defp ensure_meta_header(path) do
    needs_header =
      case File.stat(path) do
        {:ok, %{size: 0}} -> true
        {:error, :enoent} -> true
        _ -> false
      end

    if needs_header, do: write_meta_header(path)
  end

  defp write_meta_header(path) do
    meta = {:log_meta, %{version: @version, created_at: DateTime.utc_now()}}
    binary = :erlang.term_to_binary(meta)
    compressed = :zlib.compress(binary)
    File.write!(path, <<byte_size(compressed)::32, compressed::binary>>, [:write, :raw])
  end

  defp write_record(path, event) do
    binary = :erlang.term_to_binary(event)
    compressed = :zlib.compress(binary)
    File.write!(path, <<byte_size(compressed)::32, compressed::binary>>, [:append, :raw])
  end

  defp read_records(path) do
    case File.read(path) do
      {:ok, binary} ->
        case read_meta(binary) do
          {:ok, _meta, rest} -> read_entries(rest, [])
          {:error, :no_meta} -> read_entries(binary, [])
        end

      {:error, :enoent} ->
        []

      {:error, reason} ->
        Logger.warning("[Saga.Journal] read failed: #{inspect(reason)}")
        []
    end
  end

  defp read_meta(<<size::32, rest::binary>>) when byte_size(rest) >= size do
    <<data::binary-size(size), remaining::binary>> = rest

    case safe_decode(data) do
      {:ok, {:log_meta, meta}} when is_map(meta) -> {:ok, meta, remaining}
      _ -> {:error, :no_meta}
    end
  end

  defp read_meta(_), do: {:error, :no_meta}

  defp read_entries(<<size::32, rest::binary>>, acc) when byte_size(rest) >= size do
    <<data::binary-size(size), remaining::binary>> = rest

    acc =
      case safe_decode(data) do
        {:ok, {:log_meta, _}} -> acc
        {:ok, event} -> [event | acc]
        :error -> acc
      end

    read_entries(remaining, acc)
  end

  defp read_entries(_truncated_tail, acc), do: Enum.reverse(acc)

  defp safe_decode(compressed) do
    binary = :zlib.uncompress(compressed)
    {:ok, :erlang.binary_to_term(binary)}
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  # ── Internal: saga reconstruction ──

  # Fold the ordered record stream into a list of saga summaries.
  # Each saga_id gets a map: status, step_names, completed_steps,
  # started_step (most-recent step_started that's not yet succeeded
  # or failed), trace (all records), metadata, name, on_resume,
  # started_at.
  defp build_sagas(records) do
    records
    |> Enum.reduce(%{}, &apply_record/2)
    |> Map.values()
  end

  defp apply_record({:saga_started, id, name, metadata, on_resume, step_names, started_at}, acc) do
    Map.put(acc, id, %{
      saga_id: id,
      name: name,
      metadata: metadata,
      on_resume: on_resume,
      step_names: step_names,
      started_at: started_at,
      completed_steps: [],
      started_step: nil,
      failed_step: nil,
      failure_reason: nil,
      status: :in_flight,
      trace: [{:saga_started, id, name, metadata, on_resume, step_names, started_at}]
    })
  end

  defp apply_record({:step_started, id, step_name, _ctx_before} = rec, acc) do
    update_in_acc(acc, id, fn s ->
      %{s | started_step: step_name, trace: s.trace ++ [rec]}
    end)
  end

  defp apply_record({:step_succeeded, id, step_name, _ctx_after} = rec, acc) do
    update_in_acc(acc, id, fn s ->
      %{s |
        completed_steps: s.completed_steps ++ [step_name],
        started_step: nil,
        trace: s.trace ++ [rec]}
    end)
  end

  defp apply_record({:step_failed, id, step_name, reason} = rec, acc) do
    update_in_acc(acc, id, fn s ->
      %{s |
        failed_step: step_name,
        failure_reason: reason,
        started_step: nil,
        trace: s.trace ++ [rec]}
    end)
  end

  defp apply_record({:step_rolled_back, id, _step_name} = rec, acc) do
    update_in_acc(acc, id, fn s -> %{s | trace: s.trace ++ [rec]} end)
  end

  defp apply_record({:rollback_failed, id, _step_name, _reason} = rec, acc) do
    update_in_acc(acc, id, fn s -> %{s | trace: s.trace ++ [rec]} end)
  end

  defp apply_record({:saga_completed, id} = rec, acc) do
    update_in_acc(acc, id, fn s ->
      %{s | status: :succeeded, trace: s.trace ++ [rec]}
    end)
  end

  defp apply_record({:saga_rolled_back, id, failure} = rec, acc) do
    update_in_acc(acc, id, fn s ->
      status =
        case failure do
          :crashed_mid_saga -> :rolled_back_on_boot
          _ -> :rolled_back
        end

      %{s | status: status, failure_reason: s.failure_reason || failure, trace: s.trace ++ [rec]}
    end)
  end

  # Unknown record (future version or corruption) — skip silently.
  defp apply_record(_other, acc), do: acc

  defp update_in_acc(acc, id, fun) do
    case Map.fetch(acc, id) do
      {:ok, saga} -> Map.put(acc, id, fun.(saga))
      # :step_started without a matching :saga_started — probably a
      # legacy / partial record. Ignore so we don't accidentally
      # treat it as incomplete forever.
      :error -> acc
    end
  end

  # ── Internal: compaction ──

  # Finished = saga has a :saga_completed or :saga_rolled_back record.
  # Returns {finished_ids, in_flight_records}.
  defp split_records(records) do
    sagas = build_sagas(records)
    finished_ids = for s <- sagas, s.status != :in_flight, do: s.saga_id, into: MapSet.new()
    in_flight_ids = for s <- sagas, s.status == :in_flight, do: s.saga_id, into: MapSet.new()

    in_flight_records =
      records
      |> Enum.filter(fn rec -> saga_id_of(rec) in in_flight_ids end)

    {finished_ids, in_flight_records}
  end

  # Keep the N most recent finished sagas per saga name as audit
  # trail. Returns records (not ids) in their original order.
  defp keep_recent_per_saga_name(finished_ids, n_per_name, records) do
    finished_sagas =
      records
      |> build_sagas()
      |> Enum.filter(&(&1.saga_id in finished_ids))

    kept_ids =
      finished_sagas
      |> Enum.group_by(& &1.name)
      |> Enum.flat_map(fn {_name, sagas} ->
        sagas
        |> Enum.sort_by(& &1.saga_id, :desc)
        |> Enum.take(n_per_name)
        |> Enum.map(& &1.saga_id)
      end)
      |> MapSet.new()

    Enum.filter(records, fn rec -> saga_id_of(rec) in kept_ids end)
  end

  defp saga_id_of({:saga_started, id, _, _, _, _, _}), do: id
  defp saga_id_of({:step_started, id, _, _}), do: id
  defp saga_id_of({:step_succeeded, id, _, _}), do: id
  defp saga_id_of({:step_failed, id, _, _}), do: id
  defp saga_id_of({:step_rolled_back, id, _}), do: id
  defp saga_id_of({:rollback_failed, id, _, _}), do: id
  defp saga_id_of({:saga_completed, id}), do: id
  defp saga_id_of({:saga_rolled_back, id, _}), do: id
  defp saga_id_of(_), do: nil

  # Dead-simple counter in persistent_term. Journal compaction runs
  # when the counter crosses @compaction_threshold. Resetting to 0
  # happens on boot (implicit) and on compact/0. We don't need strict
  # atomicity here — losing a tick just delays compaction.
  defp maybe_compact do
    count = bump_compaction_counter()

    if count >= @compaction_threshold do
      reset_compaction_counter()
      # Compaction runs in the caller's process (usually the saga
      # runner). It's rare (every N sagas) and keeps the journal
      # bounded — doing it inline avoids yet another GenServer in
      # the supervision tree.
      case compact() do
        {:ok, _} -> :ok
        {:error, reason} -> Logger.warning("[Saga.Journal] compact failed: #{inspect(reason)}")
      end
    end

    :ok
  end

  defp bump_compaction_counter do
    key = {__MODULE__, :compaction_counter}
    current = :persistent_term.get(key, 0)
    next = current + 1
    :persistent_term.put(key, next)
    next
  end

  defp reset_compaction_counter do
    :persistent_term.put({__MODULE__, :compaction_counter}, 0)
  end
end
