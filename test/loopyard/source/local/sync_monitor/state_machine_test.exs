defmodule Loopyard.Source.Local.SyncMonitor.StateMachineTest do
  use ExUnit.Case, async: true
  alias Loopyard.Source.Local.SyncMonitor.StateMachine

  test "enumerates all five states" do
    assert Enum.sort(StateMachine.states()) ==
             Enum.sort([:starting, :running, :paused, :errored, :stopped])
  end

  test "legal transitions from :starting" do
    for to <- [:running, :errored, :paused, :stopped, :starting] do
      assert {:ok, ^to} = StateMachine.transition(:starting, to)
    end
  end

  test "legal transitions from :running" do
    for to <- [:paused, :errored, :stopped, :running] do
      assert {:ok, ^to} = StateMachine.transition(:running, to)
    end
  end

  test "legal transitions from :paused" do
    for to <- [:running, :starting, :errored, :stopped, :paused] do
      assert {:ok, ^to} = StateMachine.transition(:paused, to)
    end
  end

  test "legal transitions from :errored" do
    for to <- [:running, :starting, :paused, :stopped, :errored] do
      assert {:ok, ^to} = StateMachine.transition(:errored, to)
    end
  end

  test "stopped is terminal except for an explicit restart" do
    assert {:ok, :starting} = StateMachine.transition(:stopped, :starting)
    assert {:ok, :stopped} = StateMachine.transition(:stopped, :stopped)

    # A late probe arriving on a stopped session must not re-animate it.
    for to <- [:running, :paused, :errored] do
      assert {:error, _} = StateMachine.transition(:stopped, to)
    end
  end

  test "running cannot skip back to starting — must go through stopped" do
    assert {:error, _} = StateMachine.transition(:running, :starting)
  end
end
