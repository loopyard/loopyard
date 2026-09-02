defmodule Loopyard.ChatAgent.GhostThinkingTest do
  @moduledoc """
  Coverage for the ghost-`:thinking` self-heal in the `:send_message`
  cond of `lib/loopyard/chat_agent.ex`.

  A real in-flight turn always carries a `stream_ref` backed by a live
  session (both set in `start_turn/2`). When a turn dies WITHOUT running a
  reset-to-idle path — e.g. a session crash during a reconnect — the agent
  can be left at `status: :thinking` with `stream_ref: nil` and no live
  session. That's a GHOST: if a send falls into the busy-enqueue clause it
  parks behind a turn that can never complete or drain, and every
  subsequent message silently vanishes (observed live: agent shows
  "thinking" forever, submits do nothing).

  The fix: detect the ghost (`:thinking` + no stream + no live session) and
  self-heal to idle, then run the send for real. These tests pin both
  halves: the ghost recovers, and a GENUINE in-flight turn is untouched
  (the send still parks in the queue).
  """

  use Loopyard.AgentCase

  alias Loopyard.ChatAgent

  @moduletag timeout: 10_000

  setup do
    id = "ghost-thinking-test-#{:rand.uniform(1_000_000)}"

    {:ok, _pid} =
      Loopyard.TestHelpers.start_agent(
        id: id,
        name: "Ghost Thinking Test",
        started_by: "test"
      )

    on_exit(fn ->
      try do
        ChatAgent.stop_agent(id)
      catch
        :exit, _ -> :ok
      end

      Process.sleep(20)
    end)

    %{id: id, pid: agent_pid(id)}
  end

  defp agent_pid(id) do
    case Registry.lookup(Loopyard.ChatAgentRegistry, id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  test "recovers a ghost :thinking on send instead of wedging", %{id: id, pid: pid} do
    ref = [:loopyard, :agent, :ghost_turn_recovered]
    test_pid = self()

    :telemetry.attach(
      "ghost-recover-#{id}",
      ref,
      fn _e, _m, meta, _ -> send(test_pid, {:recovered, meta.agent_id}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach("ghost-recover-#{id}") end)

    # Force the ghost shape: status says a turn is in flight, but there's
    # no stream and no session.
    :sys.replace_state(pid, fn s ->
      %{s | status: :thinking, stream_ref: nil, session: nil, pending_sends: []}
    end)

    text = "this must run after a ghost, not vanish"
    ChatAgent.send_message(id, text)
    Process.sleep(120)

    state = :sys.get_state(pid)

    # The recovery telemetry fired.
    assert_receive {:recovered, ^id}, 1_000

    # It did NOT park in the queue (that's the wedge path).
    assert state.pending_sends == [],
           "ghost send must not park in pending_sends, got: #{inspect(state.pending_sends)}"

    # It went through the normal path: the user message was appended (a
    # real turn ran). The default test backend's empty stream completes the
    # turn, returning the agent to idle.
    assert Enum.any?(state.messages, &(&1.role == :user and &1.content == text)),
           "expected the user message to be appended via the normal send path"

    assert state.status == :idle,
           "expected idle after the recovered turn completed, got: #{inspect(state.status)}"
  end

  test "a genuine in-flight turn still parks the send (ghost guard is precise)", %{
    id: id,
    pid: pid
  } do
    # A REAL turn: live session pid + an active stream_ref. This is NOT a
    # ghost, so a send must park in pending_sends (surface #15), not run.
    {:ok, live} = Agent.start_link(fn -> :ok end)
    on_exit(fn -> if Process.alive?(live), do: Agent.stop(live) end)

    :sys.replace_state(pid, fn s ->
      %{s | status: :thinking, stream_ref: make_ref(), session: live, pending_sends: []}
    end)

    text = "queue me behind the live turn"
    ChatAgent.send_message(id, text)
    Process.sleep(80)

    state = :sys.get_state(pid)

    assert text in state.pending_sends,
           "a real in-flight turn must park the send in the queue, got: #{inspect(state.pending_sends)}"

    refute Enum.any?(state.messages, &(&1.role == :user and &1.content == text)),
           "parked message must not be appended as a user turn yet"
  end
end
