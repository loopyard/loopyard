defmodule BoomLooper.Saga do
  @moduledoc """
  Run a sequence of side-effecting steps with per-step rollback.
  Either every step succeeds, or every already-completed step's
  rollback runs in reverse order. No half-done multi-step operations.

  Move #7a in `plans/coordination-hardening.md`.

  ## The bug class this kills

  "Start a workspace" is ~5 imperative calls in a row: start the
  group supervisor, start the ServiceManager, register in
  `WorkspaceRegistry`, compose up, broadcast. Today if step 4 fails
  we're left with a registered workspace, a running supervisor tree,
  and no containers — a partial-success state the reconciler has
  to recognize and clean up after the fact.

  `Saga.run/2` flips that: each step declares its own `:rollback`.
  On any failure, already-completed rollbacks run in reverse order,
  so the observable mid-failure states are pre-op and post-op only.
  The reconciler becomes a backstop for BEAM-crash-mid-saga (see
  Move #9, saga journal) rather than a primary cleanup path.

  ## Step shape

  A step is a map with:

    * `:name` — atom identifying the step. Shows up in telemetry
      and `/system/sagas`. Required.
    * `:run` — `(context -> {:ok, updates} | {:error, reason})`.
      `updates` is a map merged into the context. Required.
    * `:rollback` — `(context -> :ok | {:error, reason})`. Optional.
      When a later step fails, every completed step's rollback runs
      in reverse order. Missing `:rollback` means the step has no
      side effect worth undoing (rare; usually a read-only step).

  Context is threaded through both the forward and rollback passes
  so step N's `:run` can see what step 1..N-1 produced and step N's
  `:rollback` can see what step N produced (under the name it put
  into the context).

  ## Return values

    * `{:ok, context}` — every step succeeded. Final context has
      every step's updates merged in.

    * `{:error, {:step_failed, name, reason}, :rolled_back}` — step
      `name` failed; every prior step's rollback succeeded.

    * `{:error, {:step_failed, name, reason}, {:rollback_failed,
      [{name, reason}, ...]}}` — step `name` failed AND one or more
      rollbacks also failed. The failed-rollback list is ordered by
      rollback execution (reverse of forward execution). This is
      the **scary case**: we couldn't fully revert, so some external
      state may be inconsistent. `/system/sagas` flags these in red.

  ## Rollback-step failure semantics

  Every rollback runs, even if an earlier rollback failed. The goal
  is best-effort reversion — skipping the rest because one failed
  would compound the damage. Failed rollbacks are collected and
  surfaced in the return; their telemetry fires the same way.

  If a rollback raises or exits, the saga catches it and records it
  as `{:error, {:exception, message}}` — a crashing rollback does
  NOT crash the saga process. The saga is usually running inside
  `handle_call` of some GenServer and crashing it out from a
  rollback would be a regression, not progress.

  ## Telemetry

  Per [plans/coordination-hardening.md](plans/coordination-hardening.md)
  Move #7a:

    * `[:boom_looper, :saga, :started]` — meta: `%{saga, step_count}`
    * `[:boom_looper, :saga, :step_succeeded]` — meta: `%{saga, step}`,
       measurements: `%{duration_us}`
    * `[:boom_looper, :saga, :step_failed]` — meta: `%{saga, step,
       reason}`, measurements: `%{duration_us}`
    * `[:boom_looper, :saga, :rolled_back]` — meta: `%{saga,
       failed_step, rolled_back_steps}`, measurements: `%{count}`
    * `[:boom_looper, :saga, :rollback_failed]` — meta: `%{saga,
       step, reason}`, measurements: `%{count: 1}`

  `BoomLooper.Saga.Recorder` listens to these events for the
  `/system/sagas` surface.

  ## GenServer note

  `Saga.run/2` is synchronous. If a saga runs inside a `handle_call`
  it blocks the GenServer for the saga's duration. For the current
  migrations (`start_workspace`, `AgentBoot.boot`) blocking is
  acceptable — these were already slow synchronous operations.

  Async/resumable sagas are move #9 (saga journal) territory.

  ## What doesn't get a saga

  Not every multi-step sequence should be a saga. The rule of thumb:

    * If a **partial-success state is observable** to other parts
      of the system (registry entry, running container, ETS summary
      broadcast), the step boundary belongs there.

    * If work is internal to a single module and can be undone by
      that module's own `terminate/2` or a process DOWN, it doesn't
      need a saga step.

  Notable non-sagas in this tree:

    * `Workspace.Destructor.destroy/1` is a **best-effort teardown**,
      not a transaction. Each step is already soft-fail-and-continue;
      the whole point is that partial teardown still makes progress.
      Adding rollback would run deletes in reverse, re-creating
      containers we just deleted. Wrong shape for a saga.

    * `ServiceManager.do_start/1` is a single compose-up plus a
      couple of book-keeping broadcasts. Its failure mode is "compose
      up returned `{:error, reason}`" which is already reported to
      the caller; rolling back a compose-up that didn't start anything
      is a no-op. Converting would add ceremony without reducing
      observable partial-success.
  """

  require Logger

  @typedoc "Name identifying a step within a saga."
  @type step_name :: atom()

  @typedoc "A map of accumulated step outputs threaded through `:run` / `:rollback`."
  @type context :: map()

  @typedoc "Forward function: takes the current context, returns updates (merged in) or an error."
  @type forward_fn :: (context() -> {:ok, map()} | {:error, term()})

  @typedoc "Rollback function: takes the final context, best-effort reverts. Errors surface but don't stop subsequent rollbacks."
  @type rollback_fn :: (context() -> :ok | {:error, term()})

  @typedoc "Step declaration. `:rollback` is optional for steps with no side effect to undo."
  @type step :: %{
          required(:name) => step_name(),
          required(:run) => forward_fn(),
          optional(:rollback) => rollback_fn()
        }

  @typedoc "Saga options."
  @type opts :: [
          name: atom(),
          context: context(),
          metadata: map()
        ]

  @typedoc "Successful saga result."
  @type ok_result :: {:ok, context()}

  @typedoc "Failed saga result."
  @type error_result ::
          {:error, {:step_failed, step_name(), term()}, :rolled_back}
          | {:error, {:step_failed, step_name(), term()},
             {:rollback_failed, [{step_name(), term()}]}}

  @type result :: ok_result() | error_result()

  @doc """
  Run a list of steps transactionally.

  Options:

    * `:name` (required) — atom naming this saga run (e.g.
      `:start_workspace`, `:boot_agent`). Drives telemetry metadata
      and the `/system/sagas` label.
    * `:context` — initial context map merged under each step's
      output. Defaults to `%{}`.
    * `:metadata` — free-form map attached to every telemetry event
      for this saga (e.g. `%{workspace_id: "..."}`). Defaults to `%{}`.

  See the module doc for the return shapes.
  """
  @spec run([step()], opts()) :: result()
  def run(steps, opts) when is_list(steps) do
    name = Keyword.fetch!(opts, :name)
    context = Keyword.get(opts, :context, %{})
    metadata = Keyword.get(opts, :metadata, %{})

    saga_id = make_saga_id()
    started_at = System.monotonic_time(:microsecond)

    :telemetry.execute(
      [:boom_looper, :saga, :started],
      %{count: 1, step_count: length(steps)},
      Map.merge(metadata, %{saga: name, saga_id: saga_id})
    )

    case run_steps(steps, context, [], name, saga_id, metadata) do
      {:ok, final_context, completed_steps} ->
        duration_us = System.monotonic_time(:microsecond) - started_at

        :telemetry.execute(
          [:boom_looper, :saga, :completed],
          %{duration_us: duration_us, step_count: length(completed_steps)},
          Map.merge(metadata, %{saga: name, saga_id: saga_id})
        )

        {:ok, final_context}

      {:error, {:step_failed, failed_step, reason}, context_at_failure, completed_steps} ->
        rollback_result = rollback_steps(completed_steps, context_at_failure, name, saga_id, metadata)

        duration_us = System.monotonic_time(:microsecond) - started_at

        case rollback_result do
          :ok ->
            :telemetry.execute(
              [:boom_looper, :saga, :rolled_back],
              %{count: length(completed_steps), duration_us: duration_us},
              Map.merge(metadata, %{
                saga: name,
                saga_id: saga_id,
                failed_step: failed_step,
                rolled_back_steps: Enum.map(completed_steps, & &1.name)
              })
            )

            {:error, {:step_failed, failed_step, reason}, :rolled_back}

          {:partial, failed_rollbacks} ->
            :telemetry.execute(
              [:boom_looper, :saga, :rolled_back],
              %{
                count: length(completed_steps) - length(failed_rollbacks),
                duration_us: duration_us
              },
              Map.merge(metadata, %{
                saga: name,
                saga_id: saga_id,
                failed_step: failed_step,
                rolled_back_steps: Enum.map(completed_steps, & &1.name),
                failed_rollbacks: Enum.map(failed_rollbacks, &elem(&1, 0))
              })
            )

            {:error, {:step_failed, failed_step, reason},
             {:rollback_failed, failed_rollbacks}}
        end
    end
  end

  # ── Forward pass ──

  defp run_steps([], context, completed, _name, _saga_id, _meta) do
    {:ok, context, Enum.reverse(completed)}
  end

  defp run_steps([step | rest], context, completed, name, saga_id, meta) do
    step = validate_step!(step)

    started_at = System.monotonic_time(:microsecond)

    case safe_run(step.run, context) do
      {:ok, updates} when is_map(updates) ->
        duration_us = System.monotonic_time(:microsecond) - started_at

        :telemetry.execute(
          [:boom_looper, :saga, :step_succeeded],
          %{duration_us: duration_us},
          Map.merge(meta, %{saga: name, saga_id: saga_id, step: step.name})
        )

        # Completed steps are accumulated in REVERSE order so we can
        # reverse them once at the end (for the success branch) or
        # iterate them forward here (for the rollback branch — which
        # then walks them newest-first to get LIFO order).
        run_steps(rest, Map.merge(context, updates), [step | completed], name, saga_id, meta)

      {:error, reason} ->
        duration_us = System.monotonic_time(:microsecond) - started_at

        :telemetry.execute(
          [:boom_looper, :saga, :step_failed],
          %{duration_us: duration_us},
          Map.merge(meta, %{
            saga: name,
            saga_id: saga_id,
            step: step.name,
            reason: inspect(reason)
          })
        )

        {:error, {:step_failed, step.name, reason}, context, Enum.reverse(completed)}

      other ->
        duration_us = System.monotonic_time(:microsecond) - started_at

        :telemetry.execute(
          [:boom_looper, :saga, :step_failed],
          %{duration_us: duration_us},
          Map.merge(meta, %{
            saga: name,
            saga_id: saga_id,
            step: step.name,
            reason: inspect(other)
          })
        )

        {:error, {:step_failed, step.name, {:bad_return, other}}, context,
         Enum.reverse(completed)}
    end
  end

  # Wrap the forward fn in try/rescue/catch so a raising step is
  # treated as a {:error, ...} result rather than crashing the
  # process running the saga. Matches the rollback wrapper — both
  # ends of a step are uniformly exception-safe.
  defp safe_run(fun, context) do
    try do
      fun.(context)
    rescue
      e -> {:error, {:exception, Exception.message(e)}}
    catch
      :exit, reason -> {:error, {:exit, reason}}
      :throw, value -> {:error, {:throw, value}}
    end
  end

  # ── Rollback pass ──

  # `completed_steps` is in forward order. We walk it in reverse so
  # the most-recently-completed step rolls back first (LIFO).
  defp rollback_steps(completed_steps, context, name, saga_id, meta) do
    failed =
      completed_steps
      |> Enum.reverse()
      |> Enum.reduce([], fn step, acc ->
        case run_rollback(step, context, name, saga_id, meta) do
          :ok -> acc
          {:error, reason} -> [{step.name, reason} | acc]
        end
      end)

    # `failed` is accumulated in rollback order (newest-first
    # because we reverse completed_steps, prepend on each failure).
    # Reverse to give callers the rollbacks in the order they ran.
    case Enum.reverse(failed) do
      [] -> :ok
      list -> {:partial, list}
    end
  end

  defp run_rollback(%{rollback: rollback_fn} = step, context, name, saga_id, meta)
       when is_function(rollback_fn, 1) do
    started_at = System.monotonic_time(:microsecond)

    result =
      try do
        rollback_fn.(context)
      rescue
        e -> {:error, {:exception, Exception.message(e)}}
      catch
        :exit, reason -> {:error, {:exit, reason}}
        :throw, value -> {:error, {:throw, value}}
      end

    duration_us = System.monotonic_time(:microsecond) - started_at

    case result do
      :ok ->
        :telemetry.execute(
          [:boom_looper, :saga, :step_rolled_back],
          %{duration_us: duration_us},
          Map.merge(meta, %{saga: name, saga_id: saga_id, step: step.name})
        )

        :ok

      {:error, reason} = err ->
        Logger.warning(
          "[Saga] #{name} rollback step #{step.name} failed: #{inspect(reason)}"
        )

        :telemetry.execute(
          [:boom_looper, :saga, :rollback_failed],
          %{count: 1, duration_us: duration_us},
          Map.merge(meta, %{
            saga: name,
            saga_id: saga_id,
            step: step.name,
            reason: inspect(reason)
          })
        )

        err

      other ->
        reason = {:bad_return, other}

        Logger.warning(
          "[Saga] #{name} rollback step #{step.name} returned bad value: #{inspect(other)}"
        )

        :telemetry.execute(
          [:boom_looper, :saga, :rollback_failed],
          %{count: 1, duration_us: duration_us},
          Map.merge(meta, %{
            saga: name,
            saga_id: saga_id,
            step: step.name,
            reason: inspect(reason)
          })
        )

        {:error, reason}
    end
  end

  # Step with no rollback — nothing to undo. Happens for read-only
  # or "register with something idempotent" steps.
  defp run_rollback(_step_without_rollback, _context, _name, _saga_id, _meta), do: :ok

  # ── Helpers ──

  defp validate_step!(%{name: name, run: run} = step) when is_atom(name) and is_function(run, 1) do
    step
  end

  defp validate_step!(other) do
    raise ArgumentError, """
    Saga step must be a map with `:name` (atom) and `:run` (1-arity fn).
    Optional `:rollback` (1-arity fn). Got: #{inspect(other)}
    """
  end

  defp make_saga_id do
    :erlang.unique_integer([:positive, :monotonic])
  end
end
