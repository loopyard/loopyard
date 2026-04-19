defmodule BoomLooper.ChatAgent.StateMachineTest do
  use ExUnit.Case, async: true

  alias BoomLooper.ChatAgent.StateMachine

  describe "the graph itself" do
    test "every declared state appears in the transition map" do
      for state <- StateMachine.states() do
        assert Map.has_key?(StateMachine.transitions(), state),
               "#{inspect(state)} is in states/0 but missing from transitions/0"
      end
    end

    test "every target in any transition list is a declared state" do
      states = MapSet.new(StateMachine.states())

      for {from, targets} <- StateMachine.transitions(),
          target <- targets do
        assert target in states,
               "transition #{inspect(from)} → #{inspect(target)} targets unknown state"
      end
    end

    test ":destroying is terminal — no outgoing transitions" do
      assert StateMachine.transitions()[:destroying] == []
    end
  end

  describe "allowed_transition?/2" do
    test "returns true for same-state no-ops" do
      for s <- StateMachine.states() do
        assert StateMachine.allowed_transition?(s, s)
      end
    end

    test "returns true for declared transitions" do
      assert StateMachine.allowed_transition?(:booting, :idle)
      assert StateMachine.allowed_transition?(:idle, :thinking)
      assert StateMachine.allowed_transition?(:thinking, :idle)
      assert StateMachine.allowed_transition?(:crashed, :idle)
      assert StateMachine.allowed_transition?(:stopped, :idle)
    end

    test "returns false for undeclared transitions" do
      # :destroying is terminal
      refute StateMachine.allowed_transition?(:destroying, :idle)
      refute StateMachine.allowed_transition?(:destroying, :thinking)
      refute StateMachine.allowed_transition?(:destroying, :stopped)

      # Can't skip directly from :booting to :thinking without becoming
      # :idle first.
      refute StateMachine.allowed_transition?(:booting, :thinking)

      # Can't resurrect a stopped session into :thinking directly.
      refute StateMachine.allowed_transition?(:stopped, :thinking)
    end

    test "returns false for unknown states" do
      refute StateMachine.allowed_transition?(:not_a_state, :idle)
      refute StateMachine.allowed_transition?(:idle, :gibberish)
    end
  end

  describe "transition/2" do
    test "returns {:ok, to} on allowed moves" do
      assert {:ok, :thinking} = StateMachine.transition(:idle, :thinking)
      assert {:ok, :idle} = StateMachine.transition(:crashed, :idle)
    end

    test "returns {:error, {:invalid_transition, from, to}} on illegal moves" do
      assert {:error, {:invalid_transition, :destroying, :idle}} =
               StateMachine.transition(:destroying, :idle)

      assert {:error, {:invalid_transition, :booting, :thinking}} =
               StateMachine.transition(:booting, :thinking)
    end
  end

  # The pure step/2 function is the heart of Move #1 from the
  # coordination hardening plan. These tests pin down the exact
  # shape of (state, event) → (new_state, effects) for every event
  # migrated so far. Since step/2 is pure we don't need any setup
  # beyond configuring the summary callback once per test run.

  describe "step/2" do
    setup do
      # Configure the summary callback once. Use a deterministic
      # function so we can assert on the ETS-put effect's value
      # without tying tests to ChatAgent's real summary shape.
      StateMachine.configure_summary(fn state ->
        %{id: state.id, name: state.name, status: state.status}
      end)

      agent = %BoomLooper.ChatAgent{
        id: "agent-#{:rand.uniform(1_000_000)}",
        name: "Pilot",
        working_dir: "/tmp",
        started_at: ~U[2026-01-01 00:00:00Z],
        started_by: "test",
        last_activity_at: ~U[2026-01-01 00:00:00Z],
        status: :idle,
        messages: [],
        tool_calls: 0,
        errors: 0
      }

      %{agent: agent}
    end

    test "{:rename, name} updates state and emits broadcast effect", %{agent: a} do
      {:ok, new_state, effects, continuation} =
        StateMachine.step(a, {:rename, "Renamed"})

      assert new_state.name == "Renamed"
      assert continuation == :noreply

      assert effects == [
               {:broadcast, "chat_agents", {:chat_agent_renamed, a.id, "Renamed"}}
             ]
    end

    test "{:rename, name} leaves status and other fields untouched", %{agent: a} do
      {:ok, new_state, _effects, _cont} = StateMachine.step(a, {:rename, "X"})

      assert new_state.status == a.status
      assert new_state.id == a.id
      assert new_state.messages == a.messages
    end

    test ":stop from :idle moves to :stopped with ETS + broadcast effects", %{agent: a} do
      {:ok, new_state, effects, continuation} = StateMachine.step(a, :stop)

      assert new_state.status == :stopped
      assert continuation == {:stop, :normal}

      expected_summary = %{id: a.id, name: a.name, status: :stopped}

      assert effects == [
               {:ets_put, :chat_agents, a.id, expected_summary},
               {:broadcast, "chat_agents", {:chat_agent_stopped, expected_summary}}
             ]
    end

    test ":stop from :thinking is allowed (same shape as :idle)", %{agent: a} do
      state = %{a | status: :thinking}
      {:ok, new_state, _effects, cont} = StateMachine.step(state, :stop)

      assert new_state.status == :stopped
      assert cont == {:stop, :normal}
    end

    test ":stop from :destroying is refused — the state machine protects against resurrecting a terminal state", %{agent: a} do
      state = %{a | status: :destroying}

      assert {:error, {:invalid_transition, :destroying, :stopped}} =
               StateMachine.step(state, :stop)
    end

    test "side effects are returned as data, not applied — step/2 is pure", %{agent: a} do
      # No PubSub subscriber, no ETS writer — just call the function.
      # If step/2 were doing IO this would blow up or leak.
      {:ok, _, effects, _} = StateMachine.step(a, :stop)

      # Nothing landed in ETS...
      assert :ets.lookup(:chat_agents, a.id) == []

      # ...but the effect list describes what SHOULD land.
      assert Enum.any?(effects, &match?({:ets_put, :chat_agents, _, _}, &1))
    end

    # ── Session lifecycle ─────────────────────────────────────────

    test "{:session_restarted, _} transitions :crashed → :idle + appends system msg", %{agent: a} do
      state = %{a | status: :crashed}
      session = :fake_session_pid

      {:ok, new_state, effects, cont} =
        StateMachine.step(state, {:session_restarted, session})

      assert cont == :noreply
      assert new_state.status == :idle
      assert new_state.session == session

      # Messages are stored newest-first internally; the newest is
      # the restart notice.
      [restart_msg | _] = new_state.messages
      assert restart_msg.role == :system
      assert restart_msg.content == "CLI session restarted"
      assert restart_msg.id != nil

      # Effects: ETS sync, status broadcast, message persist,
      # per-agent chat broadcast. In that specific order.
      assert [
               {:ets_put, :chat_agents, _id, _summary},
               {:broadcast, "chat_agents", {:chat_agent_status_changed, _, :idle}},
               {:persist_message, ^restart_msg},
               {:broadcast, _agent_topic, {:chat_message, _, ^restart_msg}}
             ] = effects
    end

    test "{:session_restart_failed, reason} appends error, bumps errors counter, no state transition", %{agent: a} do
      state = %{a | status: :crashed, errors: 2}

      {:ok, new_state, effects, cont} =
        StateMachine.step(state, {:session_restart_failed, :enoent})

      assert cont == :noreply
      # Status unchanged — we couldn't start a new session so we
      # stay where we were (crashed, idle, whatever).
      assert new_state.status == :crashed
      assert new_state.errors == 3

      [err_msg | _] = new_state.messages
      assert err_msg.role == :error
      assert err_msg.content =~ "Failed to restart session"
      assert err_msg.content =~ ":enoent"

      # No status-changed broadcast — we didn't change status.
      refute Enum.any?(effects, &match?({:broadcast, _, {:chat_agent_status_changed, _, _}}, &1))
    end

    # ── Message events ────────────────────────────────────────────

    test "{:append_external_message, msg} appends + persists + broadcasts", %{agent: a} do
      msg = %{role: :tool_result, content: "tool output", timestamp: ~U[2026-01-01 00:00:00Z]}
      {:ok, new_state, effects, :noreply} =
        StateMachine.step(a, {:append_external_message, msg})

      # Append happened — the ID got auto-filled
      [added | _] = new_state.messages
      assert added.content == "tool output"
      assert added.id != nil

      # External message doesn't trigger auto-continue because role
      # is :tool_result, not :system.
      refute Enum.any?(effects, &match?({:cast_self, _}, &1))
    end

    test "{:append_external_message, %{role: :system}} on :idle agent triggers auto-continue", %{agent: a} do
      msg = %{role: :system, content: "build complete", timestamp: ~U[2026-01-01 00:00:00Z]}
      {:ok, _new_state, effects, :noreply} =
        StateMachine.step(a, {:append_external_message, msg})

      # The auto-continue effect is what keeps agents working after
      # external system events (build done, tool callback, etc.).
      assert Enum.any?(effects, &match?({:cast_self, {:send_message, "Continue."}}, &1))
    end

    test "{:append_external_message, %{role: :system}} on :thinking agent does NOT auto-continue", %{agent: a} do
      # If the agent is already working, don't interrupt it with
      # a "Continue." that would queue mid-turn.
      state = %{a | status: :thinking}
      msg = %{role: :system, content: "build complete", timestamp: ~U[2026-01-01 00:00:00Z]}

      {:ok, _, effects, :noreply} =
        StateMachine.step(state, {:append_external_message, msg})

      refute Enum.any?(effects, &match?({:cast_self, _}, &1))
    end

    test "{:update_message, id, fn} mutates the matching message and persists the diff", %{agent: a} do
      # Seed an existing message
      existing = %{id: "msg-1", role: :tool, content: "pending", timestamp: ~U[2026-01-01 00:00:00Z]}
      state = %{a | messages: [existing]}

      {:ok, new_state, effects, :noreply} =
        StateMachine.step(state, {:update_message, "msg-1", fn m -> %{m | content: "done"} end})

      assert [%{id: "msg-1", content: "done"}] = new_state.messages

      # Persist-update effect carries only the changed fields (id
      # dropped since it's the key, not a diff).
      assert Enum.any?(effects, fn
               {:persist_message_update, "msg-1", changes} ->
                 Map.get(changes, :content) == "done" and not Map.has_key?(changes, :id)

               _ ->
                 false
             end)
    end

    test "{:update_message, unknown_id, _} is a no-op — late-arriving updates for trimmed messages", %{agent: a} do
      {:ok, new_state, effects, :noreply} =
        StateMachine.step(a, {:update_message, "ghost", fn m -> m end})

      # State unchanged, no effects. Graceful ignore.
      assert new_state == a
      assert effects == []
    end
  end
end
