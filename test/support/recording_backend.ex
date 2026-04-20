defmodule BoomLooper.TestSupport.RecordingBackend do
  @moduledoc """
  Test backend that records the opts passed to `start_session/1` and
  lets the test decide what `session_id/1` should return.

  Used to verify that ChatAgent wires `resume: <claude_session_id>`
  through every session-restart code path after a CLI crash / server
  restart / auto-reconnect. The real Claude CLI session_id survives
  only inside the ClaudeCode SDK Session pid, so before this fix all
  four restart paths spawned a fresh amnesic CLI instead of continuing
  the captured conversation.
  """

  @behaviour BoomLooper.Agent.Backend

  use Agent

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{starts: [], session_id_override: nil} end, name: __MODULE__)
  end

  def reset do
    if Process.whereis(__MODULE__) do
      Agent.update(__MODULE__, fn _ -> %{starts: [], session_id_override: nil} end)
    else
      {:ok, _} = start_link([])
      :ok
    end
  end

  def starts do
    Agent.get(__MODULE__, & &1.starts) |> Enum.reverse()
  end

  def set_session_id(sid) do
    Agent.update(__MODULE__, &Map.put(&1, :session_id_override, sid))
  end

  @impl true
  def start_session(opts) do
    Agent.update(__MODULE__, fn s -> %{s | starts: [opts | s.starts]} end)
    # Each call returns a fresh trivial GenServer pid so callers have
    # something alive to hold onto.
    {:ok, pid} = Agent.start_link(fn -> :ok end)
    {:ok, pid}
  end

  @impl true
  def stream(_session, _prompt), do: []

  @impl true
  def stop(session) do
    if is_pid(session) and Process.alive?(session) do
      Agent.stop(session, :normal)
    end

    :ok
  end

  @impl true
  def session_alive?(session), do: is_pid(session) and Process.alive?(session)

  @impl true
  def session_id(_session) do
    Agent.get(__MODULE__, & &1.session_id_override)
  end
end
