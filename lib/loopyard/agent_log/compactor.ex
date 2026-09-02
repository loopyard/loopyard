defmodule Loopyard.AgentLog.Compactor do
  @moduledoc """
  Rewrites an agent log as a minimal snapshot of its current state.

  The log is append-only: every message, message update, and agent update
  is a record. A long-running workspace accumulates tens of megabytes of
  records that collapse, on replay, to a state of only a few thousand
  messages. Replay of that history gets slow, then flaky, then fails.
  Compaction rewrites the file as exactly the record sequence needed to
  reproduce the current state from scratch: one `{:agent, id, data}`
  record per agent, followed by one `{:msg, id, msg}` per message.

  Extracted from `Loopyard.AgentLog` to keep that module under its size
  cap; `AgentLog` still exposes `compact/1`, `maybe_compact/1`, and
  `compact_keep_previous/1` as delegates, which is the API callers use.

  ## Garbage collection

  Compaction is the one moment the log can shed orphaned message runs —
  `{:msg, id, …}` records whose `{:agent, id, …}` identity record the log
  never held. Those can never be restored (see
  `Loopyard.AgentLog.restorable/1`), so every path here snapshots the
  *restorable* subset. Carrying them forward only costs bytes and re-warns
  on every boot.
  """

  alias Loopyard.AgentLog

  @default_threshold_bytes 5_000_000

  @doc """
  Rewrite the log as a minimal snapshot of its current state.

  Atomic: writes to `<path>.compacting`, then `File.rename/2`. A crash
  mid-write leaves the original file untouched.

  ## Options

    * `:log_path` — path to the log file (required)
    * `:version`  — log version (required; same semantics as `AgentLog.append/2`)

  Returns `{:ok, %{before: bytes, after: bytes, agents: n, messages: n}}`
  or `{:error, reason}`. Running on a missing file is a no-op returning
  `{:ok, %{before: 0, after: 0, agents: 0, messages: 0}}`.
  """
  def compact(opts), do: with_snapshot(opts, &do_compact/4)

  @doc """
  Compact the log iff it's bigger than the threshold.

  Called at startup (see `ServiceManager.init`) so every workspace boot
  trims its log if it's grown past the threshold. Cheap no-op when the
  file is small.

  Options:
    * `:log_path` — path to the log file (required)
    * `:version`  — log version (required)
    * `:threshold_bytes` — minimum size before compacting (default: 5 MB)
  """
  def maybe_compact(opts) do
    path = Keyword.fetch!(opts, :log_path)
    threshold = Keyword.get(opts, :threshold_bytes, @default_threshold_bytes)

    case File.stat(path) do
      {:ok, %{size: size}} when size >= threshold -> compact(opts)
      _ -> {:ok, :skipped}
    end
  end

  @doc """
  Like `compact/1`, but keeps the pre-compaction log as `<path>.prev`.

  This is the checkpoint / snapshot primitive for move #8 in
  `plans/archive/coordination-hardening.md`. Where `compact/1` rewrites the log
  and discards the old bytes, `compact_keep_previous/1` always leaves the
  prior log beside the new one so `AgentLog.replay_with_fallback/1` can
  recover from a corrupt primary.

  ## Sequencing

  The rewrite order matters for crash safety:

    1. Build the new snapshot at `<path>.compacting` (atomic writes).
    2. Rename `<path>` → `<path>.prev` (atomic on POSIX).
    3. Rename `<path>.compacting` → `<path>` (atomic on POSIX).

  Any interrupt between steps leaves the filesystem in a usable state:
  either the old primary is intact (interrupt before step 2) or the old
  primary now lives as `.prev` with the new snapshot at the primary path
  (interrupt between 2 and 3 would leave `.prev` valid and primary
  missing; `replay_with_fallback/1` recovers).

  Never deletes `.prev` here. Callers that want to trim the backup do it
  explicitly.

  Options match `compact/1`.
  """
  def compact_keep_previous(opts), do: with_snapshot(opts, &do_compact_keep_previous/4)

  # Shared preamble for both compaction modes: stat, replay, and hand the
  # RESTORABLE state to the writer. Missing file is a no-op, not an error.
  defp with_snapshot(opts, writer) do
    path = Keyword.fetch!(opts, :log_path)
    version = Keyword.fetch!(opts, :version)

    case File.stat(path) do
      {:ok, %{size: before_size}} ->
        case AgentLog.replay(log_path: path, version: version) do
          {:ok, state} ->
            writer.(path, version, AgentLog.restorable(state), before_size)

          {:error, _} = err ->
            err
        end

      {:error, :enoent} ->
        {:ok, %{before: 0, after: 0, agents: 0, messages: 0}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_compact(path, version, state, before_size) do
    temp_path = path <> ".compacting"
    File.rm(temp_path)

    message_count = build_snapshot(temp_path, version, state)

    case File.rename(temp_path, path) do
      :ok ->
        {:ok, result(path, state, before_size, message_count)}

      {:error, reason} ->
        File.rm(temp_path)
        {:error, {:rename_failed, reason}}
    end
  end

  defp do_compact_keep_previous(path, version, state, before_size) do
    temp_path = path <> ".compacting"
    prev_path = path <> ".prev"

    # Remove any leftover temp file from a previous failed compaction
    File.rm(temp_path)

    # Step 1: write the new snapshot to a temp file
    message_count = build_snapshot(temp_path, version, state)

    # Step 2: rename current log to .prev (if primary exists). If there is
    # no primary yet, this is the first snapshot and .prev is omitted —
    # there's nothing to preserve. On rename failure, leave the temp file
    # alone so the next call / manual inspection can recover.
    rotated =
      case File.stat(path) do
        {:ok, _} ->
          case File.rename(path, prev_path) do
            :ok ->
              :ok

            {:error, reason} ->
              # Leave temp file in place; original primary still intact.
              {:error, {:rename_to_prev_failed, reason}}
          end

        {:error, :enoent} ->
          :ok
      end

    case rotated do
      :ok ->
        # Step 3: rename temp file to current log
        case File.rename(temp_path, path) do
          :ok ->
            {:ok, result(path, state, before_size, message_count)}

          {:error, reason} ->
            # Temp file still at .compacting, .prev may already hold the
            # pre-compaction data. Don't delete anything — operator can
            # manually recover. replay_with_fallback/1 will use .prev on
            # next boot.
            {:error, {:rename_failed, reason}}
        end

      {:error, _} = err ->
        err
    end
  end

  # One `{:agent, id, meta}` record per agent, then all of its messages as
  # `{:msg, id, msg}`. Replaying this yields the same in-memory state we
  # started from. Returns the message count.
  defp build_snapshot(temp_path, version, state) do
    AgentLog.ensure_meta_header(temp_path, version)

    Enum.reduce(state, 0, fn {agent_id, agent_data}, acc ->
      messages = Map.get(agent_data, :messages, [])
      agent_meta = Map.delete(agent_data, :messages)

      AgentLog.write_record(temp_path, {:agent, agent_id, agent_meta})

      for msg <- messages do
        AgentLog.write_record(temp_path, {:msg, agent_id, msg})
      end

      acc + length(messages)
    end)
  end

  defp result(path, state, before_size, message_count) do
    after_size =
      case File.stat(path) do
        {:ok, %{size: s}} -> s
        _ -> 0
      end

    %{
      before: before_size,
      after: after_size,
      agents: map_size(state),
      messages: message_count
    }
  end
end
