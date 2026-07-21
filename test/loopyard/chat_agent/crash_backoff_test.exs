defmodule Loopyard.ChatAgent.CrashBackoffTest do
  use ExUnit.Case, async: false

  alias Loopyard.ChatAgent

  @moduletag timeout: 10_000

  setup do
    # Zero backoff so tests run instantly
    Application.put_env(:loopyard, :crash_backoff_base_ms, 0)
    on_exit(fn -> Application.delete_env(:loopyard, :crash_backoff_base_ms) end)

    id = "backoff-test-#{:rand.uniform(100_000)}"

    {:ok, _pid} =
      Loopyard.TestHelpers.start_agent(
        id: id,
        name: "Backoff Test",
        working_dir: File.cwd!(),
        started_by: "test"
      )

    ChatAgent.subscribe()
    ChatAgent.subscribe(id)

    on_exit(fn ->
      try do
        ChatAgent.stop_agent(id)
      catch
        :exit, _ -> :ok
      end

      Process.sleep(50)
    end)

    %{id: id}
  end

  defp agent_pid(id) do
    case Registry.lookup(Loopyard.ChatAgentRegistry, id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  describe "crash backoff" do
    test "first crash restarts and increments counter", %{id: id} do
      pid = agent_pid(id)
      assert pid != nil

      # Put agent into :thinking state so it handles EXIT messages
      :sys.replace_state(pid, fn state ->
        %{state | status: :thinking}
        |> Map.put(:consecutive_crashes, 0)
      end)

      # Simulate a linked task crash
      send(pid, {:EXIT, self(), {:error, "test crash"}})

      # Should get a status change back to :idle (restarted)
      assert_receive %Loopyard.Events.ChatAgent.StatusChanged{id: ^id, status: :idle}, 1_000

      # Counter should be 1
      state = :sys.get_state(pid)
      assert Map.get(state, :consecutive_crashes) == 1
    end

    test "gives up after max consecutive crashes", %{id: id} do
      pid = agent_pid(id)

      # Fast-forward the crash counter to just below the limit
      :sys.replace_state(pid, fn state ->
        %{state | status: :thinking}
        |> Map.put(:consecutive_crashes, 5)
      end)

      # One more crash should trigger the "give up" path
      send(pid, {:EXIT, self(), {:error, "fatal crash"}})

      # Should mark as :crashed, not :idle
      assert_receive %Loopyard.Events.ChatAgent.StatusChanged{id: ^id, status: :crashed}, 1_000
    end

    test "successful stream_done resets crash counter", %{id: id} do
      pid = agent_pid(id)

      # Set some crash history + install a known stream_ref so the
      # ref-tagged :stream_done matches.
      ref = make_ref()

      :sys.replace_state(pid, fn state ->
        %{state | status: :thinking, stream_ref: ref}
        |> Map.put(:consecutive_crashes, 3)
      end)

      # Simulate successful stream completion
      send(pid, {:stream_done, id, ref})

      assert_receive %Loopyard.Events.ChatAgent.StatusChanged{id: ^id, status: :idle}, 1_000

      state = :sys.get_state(pid)
      assert Map.get(state, :consecutive_crashes) == 0
    end
  end

  describe ":backoff state transition (audit-2 LOW #7)" do
    # Pre-fix: state.status stayed :thinking during the exponential
    # backoff window (up to 32s). UI showed "thinking" while the
    # agent was actually dead in the water. Fix: transition to a
    # new :backoff state, broadcast it, let the UI render accordingly.

    test "EXIT during :thinking transitions to :backoff and broadcasts", %{id: id} do
      # Use a longer backoff so we have time to observe the :backoff
      # state BEFORE :retry_session fires and flips back to :idle.
      Application.put_env(:loopyard, :crash_backoff_base_ms, 500)
      on_exit(fn -> Application.put_env(:loopyard, :crash_backoff_base_ms, 0) end)

      pid = agent_pid(id)
      assert pid != nil

      :sys.replace_state(pid, fn state ->
        %{state | status: :thinking}
        |> Map.put(:consecutive_crashes, 0)
      end)

      # Force EXIT; the controller should flip to :backoff and broadcast.
      send(pid, {:EXIT, self(), {:error, "boom"}})

      # Expect :backoff broadcast. This must arrive BEFORE :retry_session
      # fires (500ms), which would then flip to :idle.
      assert_receive %Loopyard.Events.ChatAgent.StatusChanged{id: ^id, status: :backoff}, 200

      state_during = :sys.get_state(pid)
      assert state_during.status == :backoff

      # ETS summary must reflect :backoff too so non-live viewers see
      # the current status.
      [{^id, summary}] = :ets.lookup(:chat_agents, id)
      assert summary.status == :backoff

      # After the backoff elapses, retry flips it to :idle.
      assert_receive %Loopyard.Events.ChatAgent.StatusChanged{id: ^id, status: :idle}, 2_000
    end
  end

  describe ":retry_session session-replacement guard" do
    # Audit-2 HIGH #2 (commit 35f07cc). The async-backoff fix kept
    # state.status = :thinking during the backoff window. A user's
    # send_message cast arriving mid-backoff called
    # ensure_session_alive, replaced state.session with a fresh pid,
    # and then the scheduled :retry_session spawned ANOTHER session —
    # orphaning one CLI process per race.
    #
    # The fix carries the dead_session pid in the 3-tuple
    # {:retry_session, consecutive, dead_session}. On fire, if
    # state.session != dead_session the handler no-ops — the new
    # session is owned by whoever replaced it.

    test "retry_session no-ops when state.session was replaced mid-backoff", %{id: id} do
      pid = agent_pid(id)
      assert pid != nil

      # Record the live session and synthesize a distinct "dead" pid
      # that the scheduled message should have been tied to. Any pid
      # != state.session triggers the guard; using self() keeps the
      # test hermetic.
      original_state = :sys.get_state(pid)
      live_session = original_state.session

      # Mark retry_from_session as if the :EXIT handler had queued a
      # retry. If the guard fires we expect it to be deleted; if not,
      # dispatch_retry_session deletes it too — so we also check
      # state.session stayed put.
      :sys.replace_state(pid, fn state ->
        state
        |> Map.put(:retry_from_session, self())
      end)

      # Capture any status broadcasts that would fire if the retry
      # path actually ran (dispatch_retry_session always publishes
      # :idle after start_session).
      dead_session = self()
      send(pid, {:retry_session, 1, dead_session})

      # Give the GenServer time to process. No StatusChanged should
      # arrive for this agent.
      refute_receive %Loopyard.Events.ChatAgent.StatusChanged{id: ^id}, 200

      new_state = :sys.get_state(pid)

      # state.session stayed exactly as it was — no new session got
      # spawned by the no-op path.
      assert new_state.session == live_session
      assert Process.alive?(new_state.session)

      # Guard cleared the retry_from_session stash.
      refute Map.has_key?(new_state, :retry_from_session) and
               Map.get(new_state, :retry_from_session) != nil

      refute Map.get(new_state, :retry_from_session)
    end

    test "retry_session fires normally when state.session matches dead_session", %{id: id} do
      pid = agent_pid(id)
      assert pid != nil

      original_state = :sys.get_state(pid)
      dead_session = original_state.session

      # Seed retry_from_session so we can check it's cleared after
      # dispatch. Also force status back to :thinking so the retry
      # transition → :idle is observable via the StatusChanged event.
      :sys.replace_state(pid, fn state ->
        state
        |> Map.put(:retry_from_session, dead_session)
        |> Map.put(:status, :thinking)
      end)

      send(pid, {:retry_session, 2, dead_session})

      # dispatch_retry_session publishes :idle on successful restart.
      assert_receive %Loopyard.Events.ChatAgent.StatusChanged{id: ^id, status: :idle}, 1_000

      new_state = :sys.get_state(pid)

      # A NEW session replaced the dead one via backend.start_session/1.
      # Fake backend returns a fresh GenServer pid each call.
      assert new_state.session != dead_session
      assert is_pid(new_state.session)
      assert Process.alive?(new_state.session)

      # retry_from_session was cleared by dispatch_retry_session.
      refute Map.get(new_state, :retry_from_session)

      # Consecutive counter was updated to the value carried by the
      # scheduled message.
      assert Map.get(new_state, :consecutive_crashes) == 2
    end
  end

  describe ":retry_session pending-sends drain" do
    # Pre-fix: a message sent while the agent was in :backoff (crash window)
    # landed in pending_sends, and a successful :retry_session reset the agent
    # to :idle WITHOUT draining the queue. :idle means no turn completion will
    # ever fire, so the message sat stranded forever — the user saw an idle
    # agent that never answered. Fix: handle_retry schedules the same
    # :drain_resumed_pending the :restart_session path uses.

    test "messages queued during the crash window drain after a successful retry", %{id: id} do
      Application.put_env(:loopyard, :pending_drain_settle_ms, 0)
      on_exit(fn -> Application.delete_env(:loopyard, :pending_drain_settle_ms) end)

      pid = agent_pid(id)
      assert pid != nil

      dead_session = :sys.get_state(pid).session

      :sys.replace_state(pid, fn state ->
        %{state | status: :backoff, pending_sends: ["queued while crashed"]}
      end)

      send(pid, {:retry_session, 1, dead_session})

      # Retry lands at :idle, then the scheduled drain starts a turn with the
      # queued message.
      assert_receive %Loopyard.Events.ChatAgent.StatusChanged{id: ^id, status: :idle}, 1_000
      assert_receive %Loopyard.Events.ChatAgent.StatusChanged{id: ^id, status: :thinking}, 1_000

      state = :sys.get_state(pid)
      assert state.pending_sends == []

      assert Enum.any?(state.messages, fn m ->
               m.role == :user and m.content == "queued while crashed"
             end)
    end
  end
end
