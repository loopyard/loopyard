defmodule BoomLooper.LogBuffer do
  @moduledoc """
  ETS-backed ring buffer for Logger messages.
  Keeps the most recent N log entries accessible via RPC.

  Installs itself as an Erlang :logger handler on start.
  """
  use GenServer

  @table :log_buffer
  @max_entries 1000
  @handler_id :boom_looper_log_buffer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc "Get the most recent `n` log entries (newest first)."
  def recent(n \\ 100) do
    if :ets.whereis(@table) != :undefined do
      [{:counter, counter}] = :ets.lookup(@table, :counter)
      start = max(0, counter - n)

      for i <- counter..start//-1,
          [{^i, entry}] <- [:ets.lookup(@table, i)] do
        entry
      end
    else
      []
    end
  end

  @doc "Get entries matching a pattern (e.g. level or message substring)."
  def grep(pattern, n \\ 200) when is_binary(pattern) do
    recent(n)
    |> Enum.filter(fn entry -> String.contains?(entry.message, pattern) end)
  end

  # --- GenServer ---

  @impl true
  def init(:ok) do
    # ETS table is owned by StateKeeper (audit-2 MEDIUM #6). The
    # previous `:ets.new/2` here meant a LogBuffer crash dropped
    # every buffered log entry AND the Logger handler kept running
    # — subsequent log lines landed in dead ETS space. StateKeeper
    # ownership means the buffer survives LogBuffer restarts.
    BoomLooper.StateKeeper.ensure_tables!()

    # Seed the monotonic counter on fresh boot. On LogBuffer
    # restart the counter survives in StateKeeper-owned ETS, so we
    # don't collide with previously-written entries.
    if :ets.lookup(@table, :counter) == [] do
      :ets.insert(@table, {:counter, 0})
    end

    # Install as an Erlang logger handler
    :logger.add_handler(@handler_id, __MODULE__, %{})

    {:ok, %{}}
  end

  # --- Erlang :logger handler callbacks ---

  @doc false
  def adding_handler(config), do: {:ok, config}

  @doc false
  def removing_handler(_config), do: :ok

  @doc false
  def log(%{level: level, msg: msg, meta: meta}, _config) do
    message = format_msg(msg)
    timestamp = Map.get(meta, :time)
    time = if timestamp, do: :calendar.system_time_to_universal_time(timestamp, :microsecond), else: nil

    entry = %{
      level: level,
      message: message,
      time: time,
      module: meta[:mfa] && elem(meta[:mfa], 0),
      pid: meta[:pid]
    }

    if :ets.whereis(@table) != :undefined do
      counter = :ets.update_counter(@table, :counter, 1)
      :ets.insert(@table, {counter, entry})

      # Clean old entries
      old = counter - @max_entries
      if old > 0, do: :ets.delete(@table, old)
    end
  end

  defp format_msg({:string, msg}), do: IO.iodata_to_binary(msg)
  defp format_msg({:report, report}), do: inspect(report)
  defp format_msg({format, args}) when is_list(args), do: :io_lib.format(format, args) |> IO.iodata_to_binary()
  defp format_msg(other), do: inspect(other)
end
