defmodule Loopyard.Harness.ACP.Connection.Diagnostics do
  @moduledoc """
  Adapter stderr diagnostics for `Loopyard.Harness.ACP.Connection`.

  The connection captures the in-container adapter's stderr to a
  per-session tmp file; when the adapter dies or wedges, its dying words
  are the diagnosis (an EMFILE watcher storm hid here for hours once).
  This module reads the tail back and logs it loudly on abnormal close,
  and sweeps stale capture files left behind by crash loops.
  """

  require Logger

  # On abnormal close, read the adapter's captured stderr tail and log it —
  # then keep the file for post-mortem. On clean shutdown, remove it.
  # Returns the tail (or nil) so the caller can classify the death — e.g.
  # a rate-limit rejection that killed the adapter.
  @stderr_tail_bytes 2_000

  def surface_dying_words(%{stderr_log: path}, reason) when is_binary(path) do
    tail =
      case File.read(path) do
        {:ok, ""} ->
          nil

        {:ok, out} ->
          binary_part(
            out,
            max(byte_size(out) - @stderr_tail_bytes, 0),
            min(byte_size(out), @stderr_tail_bytes)
          )

        _ ->
          nil
      end

    if tail do
      Logger.warning(
        "[ACP] adapter closed (#{inspect(reason)}); stderr tail (full: #{path}):\n#{tail}"
      )

      short = binary_part(tail, max(byte_size(tail) - 400, 0), min(byte_size(tail), 400))

      Loopyard.EventLog.error(
        "harness:acp",
        "Adapter closed (#{inspect(reason)}). Stderr: #{short}"
      )
    else
      # An EMPTY stderr on abnormal close is itself a diagnosis: the shell
      # inside the container never ran — the container is likely down or
      # restarting (docker exec failed before the redirect existed). Without
      # this line that failure mode was completely silent.
      Loopyard.EventLog.error(
        "harness:acp",
        "Adapter closed (#{inspect(reason)}) with NO stderr captured — " <>
          "the workspace container may be down or restarting."
      )
    end

    tail
  end

  def surface_dying_words(_state, _reason), do: nil

  @doc """
  The error a closed connection answers its waiters (and its in-flight turn)
  with. A close whose dying words say "no space left on device" is a FULL
  DOCKER DISK, not a harness crash: it becomes `{:disk_full, tail}` (which the
  ChatAgent neither auto-retries nor blames on the API) and is reported to
  `Docker.DiskMonitor`, so the inbox says so now. Anything else stays
  `{:closed, reason}`.
  """
  def close_error(stderr_tail, reason) do
    with {:disk_full, _} = error <- classify_close(stderr_tail, reason) do
      Loopyard.Docker.DiskMonitor.report_full(stderr_tail)
      error
    end
  end

  @doc "The pure half of `close_error/2`: classify without reporting."
  def classify_close(stderr_tail, reason) do
    if Loopyard.Docker.Disk.full_error?(stderr_tail),
      do: {:disk_full, tail(stderr_tail, 300)},
      else: {:closed, reason}
  end

  defp tail(text, n), do: String.slice(text, max(String.length(text) - n, 0), n)

  # Delete stderr capture files older than a day — abnormal closes keep theirs
  # for diagnosis, and a crash loop used to accumulate hundreds. Best-effort.
  def sweep_stale_stderr_logs do
    cutoff = System.os_time(:second) - 24 * 3600

    System.tmp_dir!()
    |> Path.join("loopyard-acp-*.stderr")
    |> Path.wildcard()
    |> Enum.each(fn f ->
      case File.stat(f, time: :posix) do
        {:ok, %{mtime: m}} when m < cutoff -> File.rm(f)
        _ -> :ok
      end
    end)
  rescue
    _ -> :ok
  end
end
