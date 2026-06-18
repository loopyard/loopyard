defmodule Loopyard.ChatAgent.ConcurrentSendTest do
  @moduledoc """
  Surface #15 of plans/agent-sanity.md.

  Pre-fix: two humans (or a human + a tool-triggered auto-send)
  casting `:send_message` nearly simultaneously both went to
  `send_message_normal`. Each spawned a linked Task that streamed
  from the same Claude session pid. The SDK's internal query_queue
  probably serialized them, but the result was undefined-to-us —
  interleaved TextDelta events, out-of-order tool calls, or a stream
  error from the second query.

  The fix: when a `:send_message` arrives while `state.status` is
  `:thinking` or `:backoff`, queue the text into `state.pending_sends`
  and append a visible "Queued — agent is still working on the
  previous turn" marker. On turn completion (stream_done / stream_error
  / stream_timeout / rate_limit_retry), `drain_pending_sends/1` pops
  the head and triggers `send_message_normal` inline — strict FIFO.

  Tests:
    1. Second send while :thinking enqueues + surfaces the marker;
       only one stream is active at a time.
    2. stream_done drains one pending send; a third send still queues
       behind.
    3. Queue drains in FIFO order.
  """

  use ExUnit.Case, async: false

  alias Loopyard.ChatAgent
  alias Loopyard.TestSupport.RecordingBackend

  @moduletag timeout: 10_000

  setup do
    RecordingBackend.reset()
    id = "concurrent-send-test-#{:rand.uniform(100_000)}"

    {:ok, _pid} =
      Loopyard.TestHelpers.start_agent(
        id: id,
        name: "Concurrent Send Test",
        working_dir: File.cwd!(),
        started_by: "test",
        backend: RecordingBackend
      )

    ChatAgent.subscribe()
    ChatAgent.subscribe(id)

    on_exit(fn ->
      try do
        ChatAgent.stop_agent(id)
      catch
        :exit, _ -> :ok
      end

      Process.sleep(20)
    end)

    %{id: id}
  end

  defp agent_pid(id) do
    case Registry.lookup(Loopyard.ChatAgentRegistry, id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  describe "surface #15: concurrent send serialization" do
    test "a send while :thinking parks in the queue without polluting the chat",
         %{id: id} do
      pid = agent_pid(id)

      # Put agent into :thinking to simulate a live streaming turn.
      :sys.replace_state(pid, fn s -> %{s | status: :thinking} end)

      ChatAgent.send_message(id, "second message arrives mid-turn")
      Process.sleep(50)

      state = :sys.get_state(pid)

      # Message parked in pending_sends, not started as a fresh stream.
      assert state.status == :thinking
      assert state.pending_sends == ["second message arrives mid-turn"]

      # Turn-taking: a parked message does NOT append a user bubble or a
      # "Queued" marker into the chat stream — it surfaces in the queue panel
      # and only enters the history when it's actually sent on drain.
      refute Enum.any?(state.messages, fn m ->
               m.role == :user and m.content == "second message arrives mid-turn"
             end)

      refute Enum.any?(state.messages, fn m ->
               m.role == :system and String.contains?(m.content || "", "Queued")
             end)
    end

    test "stream_done with a non-empty queue drains it as ONE batched, framed turn",
         %{id: id} do
      pid = agent_pid(id)
      ref = make_ref()

      :sys.replace_state(pid, fn s ->
        %{s | status: :thinking, stream_ref: ref, pending_sends: ["first queued", "second queued"]}
      end)

      send(pid, {:stream_done, id, ref})
      Process.sleep(100)

      state = :sys.get_state(pid)

      user_contents =
        state.messages
        |> Enum.reverse()
        |> Enum.filter(&(&1.role == :user))
        |> Enum.map(& &1.content)

      # The CHAT shows your actual individual messages — not framing machinery.
      assert user_contents == ["first queued", "second queued"]
      assert state.pending_sends == []

      # The PROMPT streamed to the model is the framed batch.
      [framed] = Loopyard.TestSupport.RecordingBackend.streamed_prompts()
      assert framed =~ "1. first queued"
      assert framed =~ "2. second queued"
      assert framed =~ "later ones may refine or correct earlier ones"
    end

    test "three rapid sends park in FIFO order, then drain as one batch", %{id: id} do
      pid = agent_pid(id)

      # Force :thinking so the very first send queues too — the true concurrent
      # race where no turn has drained yet.
      :sys.replace_state(pid, fn s -> %{s | status: :thinking} end)

      ChatAgent.send_message(id, "A")
      ChatAgent.send_message(id, "B")
      ChatAgent.send_message(id, "C")
      Process.sleep(30)

      state = :sys.get_state(pid)

      # All three parked in order; none appended to the chat yet.
      assert state.pending_sends == ["A", "B", "C"]
      assert Enum.filter(state.messages, &(&1.role == :user)) == []

      # Drain → one batched turn containing all three.
      ref = state.stream_ref
      send(pid, {:stream_done, id, ref})
      Process.sleep(100)

      state_after = :sys.get_state(pid)
      assert state_after.pending_sends == []

      # Chat shows the three individual messages...
      user_after =
        state_after.messages
        |> Enum.reverse()
        |> Enum.filter(&(&1.role == :user))
        |> Enum.map(& &1.content)

      assert user_after == ["A", "B", "C"]

      # ...but the model got one framed batch.
      [framed] = Loopyard.TestSupport.RecordingBackend.streamed_prompts()
      assert framed =~ "1. A"
      assert framed =~ "3. C"
    end
  end
end
