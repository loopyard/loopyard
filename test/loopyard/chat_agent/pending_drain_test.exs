defmodule Loopyard.ChatAgent.PendingDrainTest do
  @moduledoc """
  A queued message must always end up delivered, and the wait must be honest.

  Two defects, found chasing "turn is queued and it should be running":

    * The scheduled drain DROPPED itself whenever the agent wasn't `:idle` at
      the instant the timer fired. A running turn drains on completion, but a
      status with no completion event coming has no such rescue — the queue
      then sat forever while the UI truthfully showed "Queued" and nothing ever
      moved it. Stranded, not lost, which is the harder failure to see.

    * Sending to an agent whose harness the idle reaper had stopped published
      `:idle`. So the sidebar read "Ready" while the message sat "Queued" —
      indistinguishable from a wedged turn, and reported as one. The agent is
      neither thinking nor broken there; it is BOOTING.
  """
  use ExUnit.Case, async: true

  alias Loopyard.ChatAgent.StateMachine

  test "an idle agent may transition to :booting" do
    assert StateMachine.allowed_transition?(:idle, :booting),
           "waking a reaped harness has to be reportable as starting, not as idle"
  end

  test ":booting still leads back to a normal life" do
    assert StateMachine.allowed_transition?(:booting, :idle)
  end

  describe "PendingDrain.decide/1" do
    alias Loopyard.ChatAgent.PendingDrain

    test "nothing queued is done" do
      assert PendingDrain.decide(%{pending_sends: [], status: :thinking}) == :done
    end

    test "idle drains" do
      assert PendingDrain.decide(%{pending_sends: ["a"], status: :idle}) == :drain
    end

    test "BOOTING drains — it's the state we set while respawning a reaped harness" do
      assert PendingDrain.decide(%{pending_sends: ["a"], status: :booting}) == :drain,
             "excluding it meant the drain fired mid-respawn and dropped itself"
    end

    test "an undrainable status RETRIES rather than dropping the timer" do
      assert {:retry, 1, delay} = PendingDrain.decide(%{pending_sends: ["a"], status: :thinking})
      assert delay > 0

      assert {:retry, 2, longer} =
               PendingDrain.decide(%{pending_sends: ["a"], status: :thinking, drain_attempts: 1})

      assert longer > delay, "the backoff has to actually back off"
    end

    test "it gives up after a bounded number of attempts" do
      state = %{
        pending_sends: ["a"],
        status: :crashed,
        drain_attempts: PendingDrain.max_retries()
      }

      assert {:give_up, _} = PendingDrain.decide(state)
    end
  end

  test "waking reports :booting, never :idle" do
    src = File.read!("lib/loopyard/chat_agent.ex")

    assert src =~ ~r/status: :booting\}\)\s*\n\s*GenServer\.cast\(self\(\), :restart_session\)/,
           "the park-and-restart path must publish a visible status before restarting"
  end
end
