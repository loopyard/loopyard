defmodule Loopyard.IExSessionTest do
  use ExUnit.Case, async: true

  alias Loopyard.IExSession

  setup do
    # Start a fresh IExSession for each test
    {:ok, pid} = GenServer.start_link(IExSession, nil)
    on_exit(fn -> Process.exit(pid, :normal) end)
    %{pid: pid}
  end

  test "starts with empty state", %{pid: pid} do
    state = GenServer.call(pid, :current)
    assert state.level == nil
    assert state.label == nil
  end

  test "watching sets green level", %{pid: pid} do
    GenServer.cast(pid, {:set, :green, "Connected", node()})
    state = GenServer.call(pid, :current)
    assert state.level == :green
    assert state.label == "Connected"
  end

  test "working sets yellow level", %{pid: pid} do
    GenServer.cast(pid, {:set, :yellow, "Running eval", node()})
    state = GenServer.call(pid, :current)
    assert state.level == :yellow
    assert state.label == "Running eval"
  end

  test "destructive sets red level", %{pid: pid} do
    GenServer.cast(pid, {:set, :red, "Wiping volumes", node()})
    state = GenServer.call(pid, :current)
    assert state.level == :red
    assert state.label == "Wiping volumes"
  end

  test "disconnect clears state", %{pid: pid} do
    GenServer.cast(pid, {:set, :yellow, "Working", node()})
    GenServer.cast(pid, :disconnect)
    state = GenServer.call(pid, :current)
    assert state.level == nil
  end
end
