defmodule Loopyard.Tools.Container.DrainPortBurstTest do
  use ExUnit.Case, async: true

  alias Loopyard.Tools.Container.Helpers

  # The "port" is only ever pattern-matched, so any unique term works.
  defp fake_port, do: make_ref()

  test "drains already-queued chunks into one burst" do
    port = fake_port()
    send(self(), {port, {:data, "b"}})
    send(self(), {port, {:data, "c"}})

    assert Helpers.drain_port_burst(port, "a", 50) == "abc"
  end

  test "returns after the window even if the port stays open" do
    port = fake_port()
    started = System.monotonic_time(:millisecond)
    assert Helpers.drain_port_burst(port, "x", 60) == "x"
    assert System.monotonic_time(:millisecond) - started >= 50
  end

  test "an exit mid-drain stops the burst and is re-injected for the caller" do
    port = fake_port()
    send(self(), {port, {:data, "b"}})
    send(self(), {port, {:exit_status, 0}})
    send(self(), {port, {:data, "late"}})

    assert Helpers.drain_port_burst(port, "a", 100) == "ab"
    # The caller's normal receive loop still sees the exit.
    assert_receive {^port, {:exit_status, 0}}
  end

  test "ignores messages for other ports" do
    port = fake_port()
    other = fake_port()
    send(self(), {other, {:data, "not mine"}})
    send(self(), {port, {:data, "mine"}})

    assert Helpers.drain_port_burst(port, "", 50) == "mine"
    assert_receive {^other, {:data, "not mine"}}
  end
end
