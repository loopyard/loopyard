defmodule BoomLooper.EventLog do
  @moduledoc """
  Append-only event log for system activity. Captures lifecycle events
  (agent crashes, container deaths, session restarts, errors) so they
  can be dumped via /debug for troubleshooting.

  Events are written directly to ETS (always available regardless of
  Logger level) and also emitted to Logger for console output.
  """
  require Logger

  @ets_table :event_log
  @max_events 200

  def info(source, message) do
    write(:info, source, message)
    Logger.info(message, boom_looper: source)
  end

  def warning(source, message) do
    write(:warning, source, message)
    Logger.warning(message, boom_looper: source)
  end

  def error(source, message) do
    write(:error, source, message)
    Logger.error(message, boom_looper: source)
  end

  defp write(level, source, message) do
    key = System.monotonic_time(:nanosecond)
    event = %{
      timestamp: DateTime.utc_now(),
      level: level,
      source: source,
      message: message
    }
    :ets.insert(@ets_table, {key, event})
    trim()
  end

  @doc "Get last N events, newest first."
  def recent(n \\ 50) do
    :ets.tab2list(@ets_table)
    |> Enum.map(fn {_key, event} -> event end)
    |> Enum.reverse()
    |> Enum.take(n)
  end

  @doc "Format events as plain text for the debug endpoint."
  def dump(n \\ 50) do
    recent(n)
    |> Enum.map(fn e ->
      ts = Calendar.strftime(e.timestamp, "%H:%M:%S")
      level = e.level |> to_string() |> String.upcase() |> String.pad_trailing(5)
      "[#{ts}] #{level} [#{e.source}] #{e.message}"
    end)
    |> Enum.join("\n")
  end

  defp trim do
    size = :ets.info(@ets_table, :size)
    if size > @max_events do
      keys = :ets.tab2list(@ets_table)
             |> Enum.map(fn {k, _} -> k end)
             |> Enum.sort()
             |> Enum.take(size - @max_events)
      Enum.each(keys, &:ets.delete(@ets_table, &1))
    end
  end
end
