defmodule Loopyard.Workspace.Setup.ProgressParser do
  @moduledoc """
  Pure functions that parse `rsync --info=progress2,name1` output into
  structured progress payloads. The setup coordinator feeds rsync chunks
  through `parse_rsync_chunk/1` and broadcasts the resulting payload via
  `Events.WorkspaceSetup.PhaseProgress`.

  rsync's `--info=progress2` line shape:

      1,234,567,890  87%   12.34MB/s    0:00:23 (xfr#4231, to-chk=89/15000)

  rsync's `--info=name1` interleaves filenames as it copies them:

      app/controllers/users_controller.rb

  We extract whichever signal the chunk carries. A chunk may contain
  partial lines or several lines glued together. The caller debounces.

  Returns `nil` when the chunk has no useful progress info (rsync
  startup output, blank lines, etc.) — callers can short-circuit.
  """

  @typedoc """
  Structured progress payload. All fields optional; a chunk may carry
  any subset (e.g. just a filename, or just a percent).
  """
  @type payload :: %{
          optional(:percent) => integer(),
          optional(:bytes) => integer(),
          optional(:rate_bps) => integer(),
          optional(:eta_seconds) => integer(),
          optional(:files_done) => integer(),
          optional(:files_total) => integer(),
          optional(:current_file) => String.t()
        }

  # rsync progress2 line:
  #   "   1,234,567  87%   12.34MB/s    0:00:23 (xfr#4231, to-chk=89/15000)"
  # The xfr#/to-chk= block is optional on early lines (no transfer yet).
  @progress_re ~r/(?<bytes>[\d,]+)\s+(?<pct>\d+)%\s+(?<rate>[\d.]+)([kKmMgG]?B\/s)\s+(?<eta>\d+:\d+:\d+|\d+:\d+)(?:\s+\(xfr#(?<xfr>\d+),\s+to-chk=(?<remain>\d+)\/(?<total>\d+)\))?/

  # A bare filename — what `--info=name1` emits between progress lines.
  # Heuristic: a non-empty line with no whitespace runs that look like
  # progress numbers. We accept anything that's not progress and not
  # one of rsync's banner lines.
  @banner_prefixes ~w(sending receiving incremental file-list speedup total)

  @doc """
  Parse a chunk of rsync stdout into a structured payload, or `nil` if
  the chunk yields no useful info.

  Multi-line chunks are split on `\\n` and merged: the most recent
  progress line wins, and the most recent filename overrides any prior.
  """
  @spec parse_rsync_chunk(binary()) :: payload() | nil
  def parse_rsync_chunk(chunk) when is_binary(chunk) do
    chunk
    |> String.split(~r/[\r\n]+/, trim: true)
    |> Enum.reduce(nil, fn line, acc ->
      case parse_rsync_line(line) do
        nil -> acc
        payload -> merge(acc, payload)
      end
    end)
  end

  @doc "Parse a single rsync output line. Same payload shape as above, or nil."
  @spec parse_rsync_line(binary()) :: payload() | nil
  def parse_rsync_line(line) when is_binary(line) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" ->
        nil

      Regex.match?(@progress_re, trimmed) ->
        parse_progress(trimmed)

      banner?(trimmed) ->
        nil

      # Filename: anything else that's printable. Skip lines that look
      # like rsync's "to-chk=" debug output without the progress prefix.
      String.contains?(trimmed, "to-chk=") ->
        nil

      true ->
        %{current_file: trimmed}
    end
  end

  defp parse_progress(line) do
    case Regex.named_captures(@progress_re, line) do
      nil ->
        nil

      caps ->
        base = %{
          bytes: parse_number(caps["bytes"]),
          percent: parse_int(caps["pct"]),
          rate_bps: parse_rate(caps["rate"], extract_rate_unit(line)),
          eta_seconds: parse_eta(caps["eta"])
        }

        with_files =
          case {caps["xfr"], caps["remain"], caps["total"]} do
            {xfr, _remain, total} when xfr not in [nil, ""] and total not in [nil, ""] ->
              done = parse_int(xfr)
              total_n = parse_int(total)
              Map.merge(base, %{files_done: done, files_total: total_n})

            _ ->
              base
          end

        with_files
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)
        |> Map.new()
    end
  end

  defp extract_rate_unit(line) do
    case Regex.run(~r/[\d.]+([kKmMgG]?B\/s)/, line) do
      [_, unit] -> unit
      _ -> "B/s"
    end
  end

  defp banner?(line) do
    lower = String.downcase(line)
    Enum.any?(@banner_prefixes, &String.starts_with?(lower, &1))
  end

  defp parse_number(nil), do: nil
  defp parse_number(""), do: nil

  defp parse_number(s) do
    s
    |> String.replace(",", "")
    |> Integer.parse()
    |> case do
      {n, _} -> n
      _ -> nil
    end
  end

  defp parse_int(nil), do: nil
  defp parse_int(""), do: nil

  defp parse_int(s) do
    case Integer.parse(s) do
      {n, _} -> n
      _ -> nil
    end
  end

  defp parse_rate(nil, _), do: nil

  defp parse_rate(s, unit) do
    case Float.parse(s) do
      {n, _} -> trunc(n * unit_multiplier(unit))
      _ -> nil
    end
  end

  defp unit_multiplier("B/s"), do: 1
  defp unit_multiplier("kB/s"), do: 1_000
  defp unit_multiplier("KB/s"), do: 1_000
  defp unit_multiplier("MB/s"), do: 1_000_000
  defp unit_multiplier("GB/s"), do: 1_000_000_000
  defp unit_multiplier(_), do: 1

  # ETA in rsync is "H:MM:SS" or "M:SS"
  defp parse_eta(nil), do: nil

  defp parse_eta(s) do
    parts = String.split(s, ":") |> Enum.map(&parse_int/1)

    case parts do
      [h, m, sec] when not is_nil(h) and not is_nil(m) and not is_nil(sec) ->
        h * 3600 + m * 60 + sec

      [m, sec] when not is_nil(m) and not is_nil(sec) ->
        m * 60 + sec

      _ ->
        nil
    end
  end

  # Merge two payloads, with the newer one winning per-key. nil/missing
  # keys never overwrite a populated key.
  defp merge(nil, b), do: b

  defp merge(a, b) do
    Map.merge(a, b)
  end
end
