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
  end
end
