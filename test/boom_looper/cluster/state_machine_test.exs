defmodule BoomLooper.Cluster.StateMachineTest do
  use ExUnit.Case, async: true
  alias BoomLooper.Cluster.StateMachine

  test "every state appears in @states" do
    for s <- StateMachine.states() do
      assert is_atom(s)
    end

    assert :stopped in StateMachine.states()
    assert :starting in StateMachine.states()
    assert :started in StateMachine.states()
    assert :stopping in StateMachine.states()
  end

  test "legal transitions" do
    assert {:ok, :starting} = StateMachine.transition(:stopped, :starting)
    assert {:ok, :started} = StateMachine.transition(:starting, :started)
    assert {:ok, :stopped} = StateMachine.transition(:starting, :stopped)
    assert {:ok, :stopping} = StateMachine.transition(:started, :stopping)
    assert {:ok, :stopped} = StateMachine.transition(:stopping, :stopped)
    assert {:ok, :started} = StateMachine.transition(:stopping, :started)
  end

  test "illegal transitions" do
    assert {:error, _} = StateMachine.transition(:stopped, :started)
    assert {:error, _} = StateMachine.transition(:stopped, :stopping)
    assert {:error, _} = StateMachine.transition(:started, :stopped)
    assert {:error, _} = StateMachine.transition(:started, :starting)
    assert {:error, _} = StateMachine.transition(:starting, :stopping)
  end

  test "same-state is a no-op (legal)" do
    for s <- StateMachine.states() do
      assert {:ok, ^s} = StateMachine.transition(s, s)
    end
  end

  test "unknown state rejected" do
    assert {:error, _} = StateMachine.transition(:running, :stopped)
    assert {:error, _} = StateMachine.transition(:stopped, :exploded)
  end
end
