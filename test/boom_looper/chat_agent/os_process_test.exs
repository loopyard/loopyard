defmodule BoomLooper.ChatAgent.OSProcessTest do
  use ExUnit.Case, async: true

  alias BoomLooper.ChatAgent.OSProcess

  describe "pid_of/1" do
    test "returns nil for a dead process" do
      pid =
        spawn(fn -> :ok end)

      # Let it die
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        100 -> flunk("process didn't die")
      end

      assert OSProcess.pid_of(pid) == nil
    end

    test "returns nil for a live process with no port-holding link" do
      pid = spawn(fn -> Process.sleep(:infinity) end)
      assert OSProcess.pid_of(pid) == nil
      Process.exit(pid, :kill)
    end

    test "returns nil rather than crashing on garbage input" do
      assert OSProcess.pid_of(:not_a_pid) == nil
    end
  end

  describe "kill/1" do
    test "returns :ok even when the pid doesn't exist" do
      # A pid we're unlikely to own — kill will fail, we should not crash.
      assert :ok = OSProcess.kill(999_999_999)
    end

    test "silently handles non-integer input" do
      assert :ok = OSProcess.kill(:not_a_pid)
    end
  end
end
