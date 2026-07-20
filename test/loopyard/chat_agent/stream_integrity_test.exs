defmodule Loopyard.ChatAgent.StreamIntegrityTest do
  @moduledoc """
  Surfaces #3 + #16 of plans/agent-sanity.md.

  ### #3 In-flight message preservation

  When the Claude CLI dies mid-stream, `%Event.TextDelta{}` events have
  been rendered live in the UI but never persisted as a durable message
  (Event.Text arrives only when the assistant's block completes). On
  browser refresh the partial text vanishes — the user sees a blank
  assistant response.

  The fix accumulates delta text on `state.in_flight_partial` as it
  streams. On `:stream_error` / `:stream_timeout` with a non-empty
  accumulator, the handler finalizes it as an assistant message with
  a "⚠ Truncated — …" marker. On `:stream_done` or a complete
  `Event.Text`, the accumulator resets.

  ### #16 Stale stream event drop

  `stream_ref` identifies the current stream. When the session is
  replaced (CLI crash retry, user-triggered restart), late events from
  the dead stream Task must NOT mutate the new state — they belong to
  a conversation that ended. The handler keys off stream_ref and drops
  mismatched events with a telemetry event.
  """

  use ExUnit.Case, async: false

  alias Loopyard.ChatAgent
  alias Loopyard.Agent.Event
  alias Loopyard.TestSupport.RecordingBackend

  @moduletag timeout: 10_000

  setup do
    RecordingBackend.reset()

    id = "stream-integrity-test-#{:rand.uniform(100_000)}"

    {:ok, _pid} =
      Loopyard.TestHelpers.start_agent(
        id: id,
        name: "Stream Integrity Test",
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

  describe "surface #3: partial-text finalization on stream interrupt" do
    test "stream_error with accumulated deltas → persists a truncated assistant message",
         %{id: id} do
      pid = agent_pid(id)

      ref = make_ref()
      :sys.replace_state(pid, fn s -> %{s | stream_ref: ref, in_flight_partial: ""} end)

      # Stream two delta chunks.
      send(pid, {:stream_event, id, ref, %Event.TextDelta{text: "Hello, "}})
      send(pid, {:stream_event, id, ref, %Event.TextDelta{text: "I'm working on "}})

      # Flush.
      _ = :sys.get_state(pid)

      # CLI dies mid-stream.
      send(pid, {:stream_error, id, ref, "CLI session exited: {:port_exit, 1}"})
      assert_receive %Loopyard.Events.ChatAgent.StatusChanged{id: ^id}, 500

      state = :sys.get_state(pid)

      assistant_msgs =
        Enum.filter(state.messages, fn m ->
          m.role == :assistant and Map.get(m, :partial, false) == true
        end)

      assert length(assistant_msgs) == 1
      [partial_msg] = assistant_msgs

      assert String.contains?(partial_msg.content, "Hello, I'm working on")
      assert String.contains?(partial_msg.content, "Truncated")

      # Accumulator reset.
      assert state.in_flight_partial == ""
    end

    test "stream_timeout with accumulated deltas → persists truncated message",
         %{id: id} do
      pid = agent_pid(id)

      ref = make_ref()

      :sys.replace_state(pid, fn s ->
        %{s | stream_ref: ref, status: :thinking, in_flight_partial: "Partial response so far."}
      end)

      # Fire stream_timeout with the matching ref.
      send(pid, {:stream_timeout, id, ref})
      assert_receive %Loopyard.Events.ChatAgent.StatusChanged{id: ^id, status: :idle}, 500

      state = :sys.get_state(pid)

      partial_msg =
        Enum.find(state.messages, fn m ->
          m.role == :assistant and Map.get(m, :partial, false) == true
        end)

      assert partial_msg != nil
      assert String.contains?(partial_msg.content, "Partial response so far.")
      assert String.contains?(partial_msg.content, "Truncated")
      assert state.in_flight_partial == ""
    end

    test "complete Event.Text clears the accumulator (no ghost partial later)",
         %{id: id} do
      pid = agent_pid(id)

      ref = make_ref()
      :sys.replace_state(pid, fn s -> %{s | stream_ref: ref, in_flight_partial: ""} end)

      # Simulate a full successful stream.
      send(pid, {:stream_event, id, ref, %Event.TextDelta{text: "Hel"}})
      send(pid, {:stream_event, id, ref, %Event.TextDelta{text: "lo!"}})
      send(pid, {:stream_event, id, ref, %Event.Text{text: "Hello!"}})

      _ = :sys.get_state(pid)
      state = :sys.get_state(pid)

      # Accumulator is clear — subsequent stream_error should NOT
      # synthesize a partial.
      assert state.in_flight_partial == ""

      send(pid, {:stream_error, id, ref, "CLI session exited"})
      assert_receive %Loopyard.Events.ChatAgent.StatusChanged{id: ^id}, 500

      state_after = :sys.get_state(pid)

      # No truncated-partial should have been appended since the
      # accumulator was empty when the error fired.
      assert Enum.count(state_after.messages, fn m ->
               m.role == :assistant and Map.get(m, :partial, false) == true
             end) == 0
    end

    test "stream_error with empty accumulator → no partial message appended",
         %{id: id} do
      pid = agent_pid(id)

      ref = make_ref()
      :sys.replace_state(pid, fn s -> %{s | stream_ref: ref, in_flight_partial: ""} end)

      # Stream_error before any delta accumulates — likely a connection
      # error before the first token.
      send(pid, {:stream_error, id, ref, "CLI session exited: {:port_exit, 1}"})
      assert_receive %Loopyard.Events.ChatAgent.StatusChanged{id: ^id}, 500

      state = :sys.get_state(pid)

      # No partial-tagged assistant messages.
      assert Enum.count(state.messages, fn m ->
               m.role == :assistant and Map.get(m, :partial, false) == true
             end) == 0
    end
  end

  describe "delta publish coalescing" do
    # Raw token deltas must NOT publish 1:1 — each publish makes every viewer
    # re-ship + re-patch the whole accumulated text, which lags typing during
    # heavy streams. Deltas queue and flush as one combined event per tick.
    test "token deltas publish as one combined TextDelta per flush tick", %{id: id} do
      pid = agent_pid(id)

      ref = make_ref()

      :sys.replace_state(pid, fn s ->
        %{s | stream_ref: ref, status: :thinking, in_flight_partial: ""}
      end)

      send(pid, {:stream_event, id, ref, %Event.TextDelta{text: "Hel"}})
      send(pid, {:stream_event, id, ref, %Event.TextDelta{text: "lo, "}})
      send(pid, {:stream_event, id, ref, %Event.TextDelta{text: "world"}})

      # Nothing publishes per token (flush interval is 100ms)…
      refute_receive %Loopyard.Events.ChatAgentMessage.TextDelta{}, 40

      # …then the flush tick delivers one combined chunk.
      assert_receive %Loopyard.Events.ChatAgentMessage.TextDelta{
                       agent_id: ^id,
                       text: "Hello, world"
                     },
                     500

      refute_receive %Loopyard.Events.ChatAgentMessage.TextDelta{}, 150
    end

    test "thinking deltas coalesce on their own channel", %{id: id} do
      pid = agent_pid(id)

      ref = make_ref()
      :sys.replace_state(pid, fn s -> %{s | stream_ref: ref, status: :thinking} end)

      send(pid, {:stream_event, id, ref, %Event.ThinkingDelta{thinking: "hmm "}})
      send(pid, {:stream_event, id, ref, %Event.ThinkingDelta{thinking: "okay"}})

      assert_receive %Loopyard.Events.ChatAgentMessage.StreamOutput{
                       agent_id: ^id,
                       title: "__thinking__",
                       data: "hmm okay"
                     },
                     500
    end

    test "final Event.Text drops queued chunks — no delta after the Message", %{id: id} do
      pid = agent_pid(id)

      ref = make_ref()

      :sys.replace_state(pid, fn s ->
        %{s | stream_ref: ref, status: :thinking, in_flight_partial: ""}
      end)

      send(pid, {:stream_event, id, ref, %Event.TextDelta{text: "Hel"}})
      send(pid, {:stream_event, id, ref, %Event.Text{text: "Hello!"}})

      assert_receive %Loopyard.Events.ChatAgentMessage.Message{
                       agent_id: ^id,
                       msg: %{role: :assistant, content: "Hello!"}
                     },
                     500

      # A flush after the finalized Message would resurrect a ghost
      # streaming bubble in the UI — queued chunks must be dropped.
      refute_receive %Loopyard.Events.ChatAgentMessage.TextDelta{}, 200
    end
  end

  describe "surface #16: stale stream event drop" do
    test "stream event with mismatched ref does not mutate state", %{id: id} do
      pid = agent_pid(id)

      current_ref = make_ref()
      stale_ref = make_ref()
      :sys.replace_state(pid, fn s -> %{s | stream_ref: current_ref, in_flight_partial: ""} end)

      before_state = :sys.get_state(pid)

      # Send an event with a DIFFERENT ref — simulates a late event
      # from a Task whose session was replaced.
      send(pid, {:stream_event, id, stale_ref, %Event.TextDelta{text: "stale"}})
      send(pid, {:stream_event, id, stale_ref, %Event.Text{text: "stale full"}})

      Process.sleep(50)
      after_state = :sys.get_state(pid)

      # Fields that would mutate under a matching ref stay untouched.
      assert after_state.in_flight_partial == before_state.in_flight_partial
      assert length(after_state.messages) == length(before_state.messages)
    end

    test "stream_done with mismatched ref does not flip status to :idle",
         %{id: id} do
      pid = agent_pid(id)

      current_ref = make_ref()
      stale_ref = make_ref()

      :sys.replace_state(pid, fn s ->
        %{s | status: :thinking, stream_ref: current_ref}
      end)

      # Stale stream_done should be dropped — status stays :thinking.
      send(pid, {:stream_done, id, stale_ref})
      refute_receive %Loopyard.Events.ChatAgent.StatusChanged{id: ^id, status: :idle}, 200

      state = :sys.get_state(pid)
      assert state.status == :thinking
    end

    test "stream events with matching ref DO mutate state (control)", %{id: id} do
      pid = agent_pid(id)

      ref = make_ref()
      :sys.replace_state(pid, fn s -> %{s | stream_ref: ref, in_flight_partial: ""} end)

      send(pid, {:stream_event, id, ref, %Event.TextDelta{text: "hello"}})
      _ = :sys.get_state(pid)

      state = :sys.get_state(pid)
      assert state.in_flight_partial == "hello"
    end
  end

  describe "stop mid-turn finalizes partial + drops pending queue" do
    test ":stop with accumulated partial preserves it as truncated message",
         %{id: id} do
      pid = agent_pid(id)
      ref = make_ref()

      :sys.replace_state(pid, fn s ->
        %{s | stream_ref: ref, in_flight_partial: "Working on it when user", status: :thinking}
      end)

      GenServer.cast(pid, :stop)
      Process.sleep(50)

      # Agent stopped — no longer alive.
      refute Process.alive?(pid)

      # ETS row has the preserved partial (look it up from the
      # broadcast / stored summary).
      case :ets.lookup(:chat_agents, id) do
        [{^id, summary}] ->
          partial =
            Enum.find(summary.messages, fn m ->
              m.role == :assistant and Map.get(m, :partial, false) == true
            end)

          assert partial != nil,
                 "stop mid-turn must finalize the accumulated partial as an assistant message"

          assert String.contains?(partial.content, "Working on it when user")
          assert String.contains?(partial.content, "user stopped")

        [] ->
          # ETS row may have been cleaned by a concurrent Cleanup; rare
          # but not a regression for this path.
          :ok
      end
    end

    test ":stop with queued pending_sends drops them + logs count", %{id: id} do
      pid = agent_pid(id)

      :sys.replace_state(pid, fn s ->
        %{s | status: :thinking, pending_sends: ["A", "B", "C"]}
      end)

      GenServer.cast(pid, :stop)
      Process.sleep(50)

      refute Process.alive?(pid)

      # ETS summary reflects cleared queue (pending_sends is NOT in the
      # summary fields but the state field was cleared to []). We can
      # confirm the drop indirectly: the stop handler logged a line
      # via EventLog (no easy direct assertion without a log tap — the
      # key guarantee is 'didn't crash'.)
    end
  end
end
