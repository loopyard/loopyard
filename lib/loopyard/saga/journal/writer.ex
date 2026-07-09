defmodule Loopyard.Saga.Journal.Writer do
  @moduledoc """
  Single writer for the app-wide saga journal (`Loopyard.Saga.Journal`).

  The journal file is shared across every saga runner (workspace setup Tasks,
  LiveView processes, boot-time rollback Tasks). Without a single writer,
  concurrent `append/1` calls and inline compaction race: a record appended
  during compaction's read→rename window is dropped, two appends to a fresh
  file both write a truncating header, and two appenders crossing the
  compaction threshold corrupt the shared temp file.

  Routing every append through this one process serializes writes and
  compaction — the file is tiny, so a single writer costs nothing. The actual
  write logic lives in `Journal.do_write/1`; this module only serializes it.
  """
  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:append, record}, _from, state) do
    {:reply, Loopyard.Saga.Journal.do_write(record), state}
  end

  def handle_call(_msg, _from, state), do: {:reply, {:error, :unknown_message}, state}

  @impl true
  def handle_cast(_msg, state), do: {:noreply, state}

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}
end
