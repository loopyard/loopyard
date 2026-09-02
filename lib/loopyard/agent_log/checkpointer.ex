defmodule Loopyard.AgentLog.Checkpointer do
  @moduledoc """
  Per-workspace snapshot scheduler for the agent log.

  Move #8 in `plans/archive/coordination-hardening.md`: bound log replay time
  by periodically snapshotting the log and keeping the previous
  snapshot as a fallback. Builds on top of
  `Loopyard.AgentLog.compact_keep_previous/1` — this module decides
  *when* to snapshot, not *how*.

  ## Triggers

  A snapshot runs when either of these fires first:

    * **Interval** — every `:interval_ms` (configurable, default 30 min).
    * **Record-count** — `notify_write/1` has been called
      `:records_threshold` times since the last snapshot (default 5000).

  The first trigger wins; the counter + scheduled tick are both reset
  on snapshot. This means bursty workloads get snapshotted sooner (via
  threshold) while quiet workspaces still snapshot regularly (via
  interval).

  ## Why per-workspace (not global)?

  Reliability argument for isolation: a failing snapshot on
  workspace A must not block snapshots on workspace B. Each
  workspace already lives in its own `WorkspaceGroup` supervisor;
  wiring one Checkpointer per group fits the existing tree. The
  alternative — one global Checkpointer iterating every log —
  means a long write or a crash on one path delays every other
  workspace's checkpoint.

  Supervision overhead is trivial (one extra GenServer per
  workspace, which already has ServiceManager + AgentSupervisor
  + ContainerMonitor + RestartController). Reliability wins.

  ## Telemetry

    * `[:loopyard, :checkpoint, :written]` — successful snapshot.
      Measurements: `%{before_bytes, after_bytes, records}`.
      Metadata: `%{workspace_id, path}`.
    * `[:loopyard, :checkpoint, :failed]` — snapshot attempt errored.
      Metadata: `%{workspace_id, reason}`.

  (The `:fallback_used` event is emitted by
  `AgentLog.replay_with_fallback/1`, not here.)

  ## Failure posture

  A snapshot can fail (disk full, rename race, etc). The Checkpointer
  does not crash — it logs + telemetry-emits + resets its counters
  and tries again on the next tick. A broken checkpointer would
  defeat its own purpose by forcing a supervisor restart storm.
  """
  use GenServer
  require Logger

  # Reasonable defaults: snapshot every 30 min, or every 5,000 records
  # since last snapshot. These are the two "naturally-bounded" limits
  # we want — time bound catches quiet workspaces, record bound catches
  # busy ones.
  @default_interval_ms 30 * 60 * 1_000
  @default_records_threshold 5_000

  defstruct [
    :workspace_id,
    :log_path,
    :version,
    :interval_ms,
    :records_threshold,
    :last_checkpoint_at,
    :last_result,
    records_since_checkpoint: 0,
    timer_ref: nil
  ]

  # ── Public API ──

  @doc """
  Start a Checkpointer for a workspace.

  Options:

    * `:workspace_id` (required) — label for telemetry / logs.
    * `:log_path` (required) — agent log file path.
    * `:version` (required) — log version (passed through to
      `AgentLog.compact_keep_previous/1`).
    * `:interval_ms` — tick interval (default 30 min).
    * `:records_threshold` — record-count trigger (default 5000).
    * `:name` — registered name (defaults to unregistered; per-workspace
      supervision uses `via/1` tuples instead of atom names).
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name)

    gen_opts = if name, do: [name: name], else: []

    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Increment the record-count trigger. Cheap cast — callers should not
  block on checkpointing.

  `pid` can be a pid, a registered atom, or a `{:via, ...}` tuple.
  """
  def notify_write(pid) do
    GenServer.cast(pid, :notify_write)
  end

  @doc """
  Run a snapshot immediately (blocks until the compaction finishes or
  errors). Primarily for tests and `mix loopyard.rpc` debugging.
  """
  def force_checkpoint(pid) do
    GenServer.call(pid, :force_checkpoint, 60_000)
  end

  @doc """
  Append a record to the agent log THROUGH the checkpointer, so it is the
  single writer of the log file.

  This is what makes compaction race-free: appends and `compact_keep_previous`
  both run in this one process, so an append can never land in the window
  where the primary log is being renamed to `.prev` and replaced — the exact
  race that silently dropped records across restart.

  A **cast**, not a call: the hot path (every message persist, several/sec per
  streaming agent) must not block on this GenServer, or all agents in a
  workspace serialize their boots/turns through it (that blew the CI test
  timeouts). Casts from one agent stay FIFO-ordered, and the single process
  still serializes across agents — so durability ordering holds. The caller
  already tolerates persistence loss (serves from memory); a write failure is
  logged + telemetry'd here instead of returned.
  """
  def append(pid, event) do
    GenServer.cast(pid, {:append, event})
  end

  @doc """
  Snapshot status for `/system/recovery`. Returns a map with current
  counter, last checkpoint timestamp, last compact stats, and the
  current primary log size.
  """
  def status(pid) do
    GenServer.call(pid, :status, 5_000)
  end

  @doc """
  Via tuple for a workspace's Checkpointer. Mirrors the pattern used
  by other per-workspace registries.
  """
  def via(workspace_id) do
    {:via, Registry, {Loopyard.AgentLog.CheckpointerRegistry, workspace_id}}
  end

  @doc """
  Status for every running Checkpointer in the cluster. Drives
  `/system/recovery`.

  Returns a list of status maps (same shape as `status/1`). Safe to
  call from LiveViews — each status call is bounded by the individual
  5s GenServer timeout and failures of one checkpointer don't stop the
  others.
  """
  def list_all do
    case :ets.whereis(Loopyard.AgentLog.CheckpointerRegistry) do
      :undefined ->
        []

      _ ->
        Loopyard.AgentLog.CheckpointerRegistry
        |> Registry.select([{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
        |> Enum.flat_map(fn {workspace_id, pid} ->
          try do
            [status(pid)]
          catch
            # A checkpointer that's dying or unresponsive should not
            # prevent the page from loading other workspaces' status.
            :exit, _ ->
              [
                %{
                  workspace_id: workspace_id,
                  log_path: nil,
                  records_since_checkpoint: 0,
                  last_checkpoint_at: nil,
                  last_result: {:error, :unresponsive},
                  current_log_bytes: 0,
                  prev_log_bytes: 0
                }
              ]
          end
        end)
    end
  end

  # ── Callbacks ──

  @impl true
  def init(opts) do
    workspace_id = Keyword.fetch!(opts, :workspace_id)
    log_path = Keyword.fetch!(opts, :log_path)
    version = Keyword.fetch!(opts, :version)
    interval_ms = Keyword.get(opts, :interval_ms, @default_interval_ms)
    records_threshold = Keyword.get(opts, :records_threshold, @default_records_threshold)

    state = %__MODULE__{
      workspace_id: workspace_id,
      log_path: log_path,
      version: version,
      interval_ms: interval_ms,
      records_threshold: records_threshold
    }

    {:ok, schedule_tick(state)}
  end

  @impl true
  def handle_cast(:notify_write, state) do
    new_count = state.records_since_checkpoint + 1

    state = %{state | records_since_checkpoint: new_count}

    if new_count >= state.records_threshold do
      {:noreply, run_checkpoint(state)}
    else
      {:noreply, state}
    end
  end

  def handle_cast({:append, event}, state) do
    result =
      try do
        Loopyard.AgentLog.append(event, log_path: state.log_path, version: state.version)
        :ok
      rescue
        e -> {:error, Exception.message(e)}
      catch
        kind, reason -> {:error, inspect({kind, reason})}
      end

    # The append IS the record-count trigger now (it replaces notify_write on
    # the single-writer path). Only advance the counter on a successful write.
    # On failure, log + telemetry here (the caster can't see the result) so
    # persistence errors stay observable at /system/events.
    case result do
      :ok ->
        new_count = state.records_since_checkpoint + 1
        state = %{state | records_since_checkpoint: new_count}
        state = if new_count >= state.records_threshold, do: run_checkpoint(state), else: state
        {:noreply, state}

      {:error, reason} ->
        Logger.warning(
          "[Checkpointer] agent-log append failed for workspace #{state.workspace_id}: #{inspect(reason)}"
        )

        :telemetry.execute(
          [:loopyard, :persistence, :error],
          %{count: 1},
          %{workspace_id: state.workspace_id, path: state.log_path, reason: reason}
        )

        {:noreply, state}
    end
  end

  @impl true
  def handle_call(:force_checkpoint, _from, state) do
    result = attempt_checkpoint(state)

    state = %{
      state
      | records_since_checkpoint: 0,
        last_checkpoint_at: DateTime.utc_now(),
        last_result: result
    }

    {:reply, result, schedule_tick(state)}
  end

  def handle_call(:status, _from, state) do
    reply = %{
      workspace_id: state.workspace_id,
      log_path: state.log_path,
      records_since_checkpoint: state.records_since_checkpoint,
      last_checkpoint_at: state.last_checkpoint_at,
      last_result: state.last_result,
      current_log_bytes: current_log_bytes(state.log_path),
      prev_log_bytes: current_log_bytes(state.log_path <> ".prev")
    }

    {:reply, reply, state}
  end

  @impl true
  def handle_info(:tick, state) do
    {:noreply, run_checkpoint(state)}
  end

  def handle_info(msg, state) do
    Logger.warning(
      "[AgentLog.Checkpointer] ws=#{state.workspace_id} unhandled: #{inspect(msg, limit: 200)}"
    )

    :telemetry.execute(
      [:loopyard, :actor, :unknown_message],
      %{count: 1},
      %{actor: __MODULE__, workspace_id: state.workspace_id, msg: inspect(msg, limit: 200)}
    )

    {:noreply, state}
  end

  # ── Internals ──

  defp run_checkpoint(state) do
    result = attempt_checkpoint(state)

    state
    |> Map.put(:records_since_checkpoint, 0)
    |> Map.put(:last_checkpoint_at, DateTime.utc_now())
    |> Map.put(:last_result, result)
    |> schedule_tick()
  end

  defp attempt_checkpoint(state) do
    case Loopyard.AgentLog.compact_keep_previous(
           log_path: state.log_path,
           version: state.version
         ) do
      {:ok, stats} ->
        :telemetry.execute(
          [:loopyard, :checkpoint, :written],
          %{
            before_bytes: stats.before,
            after_bytes: stats.after,
            records: stats.agents + stats.messages
          },
          %{workspace_id: state.workspace_id, path: state.log_path}
        )

        {:ok, stats}

      {:error, reason} = err ->
        :telemetry.execute(
          [:loopyard, :checkpoint, :failed],
          %{count: 1},
          %{workspace_id: state.workspace_id, reason: reason, path: state.log_path}
        )

        Logger.warning(
          "[Checkpointer] Snapshot failed for workspace #{state.workspace_id}: #{inspect(reason)}"
        )

        err
    end
  rescue
    e ->
      # Compaction raised — treat as failure, don't crash the
      # checkpointer. Next tick will retry.
      reason = {:exception, Exception.message(e)}

      :telemetry.execute(
        [:loopyard, :checkpoint, :failed],
        %{count: 1},
        %{workspace_id: state.workspace_id, reason: reason, path: state.log_path}
      )

      Logger.error(
        "[Checkpointer] Snapshot exception for workspace #{state.workspace_id}: #{Exception.message(e)}"
      )

      {:error, reason}
  end

  defp schedule_tick(state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    ref = Process.send_after(self(), :tick, state.interval_ms)
    %{state | timer_ref: ref}
  end

  defp current_log_bytes(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end
end
