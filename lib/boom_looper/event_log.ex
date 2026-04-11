defmodule BoomLooper.EventLog do
  @moduledoc """
  Append-only event log for system activity. Captures lifecycle events
  (agent crashes, container deaths, session restarts, errors) so they
  can be dumped via /debug for troubleshooting.
  """

  @ets_table :event_log
  @max_events 200

  @doc "Log an event. Source is like 'agent:Setup', 'service:dev', 'docker', 'system'."
  def log(level, source, message) do
    key = System.monotonic_time(:nanosecond)
    event = %{
      timestamp: DateTime.utc_now(),
      level: level,
      source: source,
      message: message
    }
    :ets.insert(@ets_table, {key, event})
    trim()
    :ok
  end

  def info(source, message), do: log(:info, source, message)
  def warning(source, message), do: log(:warning, source, message)
  def error(source, message), do: log(:error, source, message)

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
