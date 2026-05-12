defmodule Loopyard.Service.StateMachineTest do
  use ExUnit.Case, async: true
  alias Loopyard.Service.StateMachine

  test "every state appears in @states" do
    assert Enum.sort(StateMachine.states()) ==
             Enum.sort([:stopped, :starting, :started, :stopping])
  end

  test "legal transitions" do
    assert {:ok, :starting} = StateMachine.transition(:stopped, :starting)
    assert {:ok, :started} = StateMachine.transition(:starting, :started)
    assert {:ok, :stopped} = StateMachine.transition(:starting, :stopped)
    assert {:ok, :stopping} = StateMachine.transition(:started, :stopping)
    # Container exiting on its own (crash, OOM) → started → stopped directly
    assert {:ok, :stopped} = StateMachine.transition(:started, :stopped)
    assert {:ok, :stopped} = StateMachine.transition(:stopping, :stopped)
    assert {:ok, :started} = StateMachine.transition(:stopping, :started)
  end

  test "illegal transitions" do
    assert {:error, _} = StateMachine.transition(:stopped, :started)
    assert {:error, _} = StateMachine.transition(:stopped, :stopping)
    assert {:error, _} = StateMachine.transition(:started, :starting)
    assert {:error, _} = StateMachine.transition(:starting, :stopping)
  end

  test "same-state is a no-op (legal)" do
    for s <- StateMachine.states() do
      assert {:ok, ^s} = StateMachine.transition(s, s)
    end
  end
end
