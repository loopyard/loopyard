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

  describe ":backoff state (audit-2 LOW #7)" do
    test ":backoff is a declared state" do
      assert :backoff in StateMachine.states()
    end

    test ":thinking → :backoff is allowed (enters the backoff window on a stream crash)" do
      assert StateMachine.allowed_transition?(:thinking, :backoff)
      assert {:ok, :backoff} = StateMachine.transition(:thinking, :backoff)
    end

    test ":backoff → :idle is allowed (successful retry)" do
      assert StateMachine.allowed_transition?(:backoff, :idle)
    end

    test ":backoff → :crashed is allowed (retry exhaustion / give up)" do
      assert StateMachine.allowed_transition?(:backoff, :crashed)
    end

    test ":backoff can be stopped or destroyed mid-window" do
      assert StateMachine.allowed_transition?(:backoff, :stopped)
      assert StateMachine.allowed_transition?(:backoff, :destroying)
    end

    test ":backoff → :thinking directly is NOT allowed (must go through :idle first)" do
      refute StateMachine.allowed_transition?(:backoff, :thinking)
    end
  end

  describe ":rate_limited state" do
    test ":rate_limited is a declared state" do
      assert :rate_limited in StateMachine.states()
    end

    test ":thinking → :rate_limited + :idle → :rate_limited are both allowed" do
      assert StateMachine.allowed_transition?(:thinking, :rate_limited)
      assert StateMachine.allowed_transition?(:idle, :rate_limited)
    end

    test ":rate_limited → :idle is allowed (successful retry)" do
      assert StateMachine.allowed_transition?(:rate_limited, :idle)
    end

    test ":rate_limited can pivot to :auth_expired (rate limit coupled with auth)" do
      assert StateMachine.allowed_transition?(:rate_limited, :auth_expired)
    end

    test ":rate_limited can be stopped or destroyed mid-wait" do
      assert StateMachine.allowed_transition?(:rate_limited, :stopped)
      assert StateMachine.allowed_transition?(:rate_limited, :destroying)
    end
  end

  describe ":auth_expired state" do
    test ":auth_expired is a declared state" do
      assert :auth_expired in StateMachine.states()
    end

    test ":thinking → :auth_expired + :idle → :auth_expired are both allowed" do
      assert StateMachine.allowed_transition?(:thinking, :auth_expired)
      assert StateMachine.allowed_transition?(:idle, :auth_expired)
    end

    test ":auth_expired → :idle allowed (user re-authenticated)" do
      assert StateMachine.allowed_transition?(:auth_expired, :idle)
    end

    test ":auth_expired → :crashed allowed (underlying CLI may die)" do
      assert StateMachine.allowed_transition?(:auth_expired, :crashed)
    end

    test ":auth_expired can be stopped or destroyed" do
      assert StateMachine.allowed_transition?(:auth_expired, :stopped)
      assert StateMachine.allowed_transition?(:auth_expired, :destroying)
    end
  end
end
