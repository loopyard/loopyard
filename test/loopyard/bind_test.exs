defmodule Loopyard.BindTest do
  @moduledoc """
  Binding is a boot flag, not runtime state.

  This replaced a UI toggle that could strand a remote user: it was reachable
  over the very connection it controlled, so disabling exposure from a phone
  severed the only link and left no way back short of physical access. The
  parsing here is the whole contract, and it must fail SAFE — a garbled value
  becomes loopback, never a surprise 0.0.0.0.
  """
  use ExUnit.Case, async: false

  alias Loopyard.Bind

  setup do
    before = System.get_env("LOOPYARD_BIND")

    on_exit(fn ->
      if before,
        do: System.put_env("LOOPYARD_BIND", before),
        else: System.delete_env("LOOPYARD_BIND")
    end)

    :ok
  end

  describe "configured_ip/0" do
    test "defaults to loopback when unset" do
      System.delete_env("LOOPYARD_BIND")
      assert Bind.configured_ip() == {127, 0, 0, 1}
    end

    test "empty string is treated as unset, not as an error" do
      System.put_env("LOOPYARD_BIND", "")
      assert Bind.configured_ip() == {127, 0, 0, 1}
    end

    test "0.0.0.0 opts into LAN exposure" do
      System.put_env("LOOPYARD_BIND", "0.0.0.0")
      assert Bind.configured_ip() == {0, 0, 0, 0}
    end

    test "surrounding whitespace is tolerated" do
      System.put_env("LOOPYARD_BIND", "  0.0.0.0  ")
      assert Bind.configured_ip() == {0, 0, 0, 0}
    end

    test "a specific interface address is honored" do
      System.put_env("LOOPYARD_BIND", "10.0.1.129")
      assert Bind.configured_ip() == {10, 0, 1, 129}
    end

    test "garbage FAILS SAFE to loopback rather than exposing the machine" do
      System.put_env("LOOPYARD_BIND", "yes-please")
      assert Bind.configured_ip() == {127, 0, 0, 1}

      System.put_env("LOOPYARD_BIND", "0.0.0")
      assert Bind.configured_ip() == {127, 0, 0, 1}
    end
  end

  describe "exposed?/0 and describe/0" do
    test "report the endpoint's ACTUAL binding, not the env var" do
      # Test env binds loopback (config/test.exs), so this must read false even
      # if someone exported LOOPYARD_BIND=0.0.0.0 in their shell — the running
      # server is what matters.
      System.put_env("LOOPYARD_BIND", "0.0.0.0")

      refute Bind.exposed?()
      assert Bind.describe() =~ "127.0.0.1:"
    end
  end
end
