defmodule Loopyard.ChatAgent.StreamHandler.FailedTurnTest do
  @moduledoc """
  A turn (or a harness launch) that failed because the Docker disk is full is
  classified as that: not auto-retried into the same full disk, not blamed on
  the API, and named with the one action.
  """
  use ExUnit.Case, async: true

  alias Loopyard.ChatAgent.SessionManager
  alias Loopyard.ChatAgent.StreamHandler.FailedTurn
  alias Loopyard.Harness.ACP.Connection.Diagnostics

  @enospc "OCI runtime exec failed: exec failed: unable to start container process: " <>
            "write /tmp/runc-process123: no space left on device: unknown"

  test "the connection classifies an ENOSPC death as {:disk_full, _}, anything else unchanged" do
    assert {:disk_full, tail} = Diagnostics.classify_close(@enospc, {:exit_status, 126})
    assert tail =~ "no space left on device"

    assert Diagnostics.classify_close("Error: boom", {:exit_status, 1}) ==
             {:closed, {:exit_status, 1}}

    assert Diagnostics.classify_close(nil, :normal) == {:closed, :normal}
  end

  test "disk_full?/1 reads every shape the reason travels in" do
    # The Translator inspects a non-binary error into the SessionResult subtype.
    assert FailedTurn.disk_full?(inspect({:disk_full, @enospc}))
    assert FailedTurn.disk_full?({:disk_full, "x"})
    assert FailedTurn.disk_full?(@enospc)
    refute FailedTurn.disk_full?("overloaded_error")
    refute FailedTurn.disk_full?(inspect({:closed, {:exit_status, 1}}))
  end

  test "the copy names the disk and the action, never the API" do
    copy = FailedTurn.copy(inspect({:disk_full, @enospc}), 3)
    assert copy =~ "disk is full"
    assert copy =~ "mix loopyard.gc"
    refute copy =~ "Anthropic"
    refute copy =~ "retries"

    assert FailedTurn.copy("overloaded_error", 3) =~ "Anthropic's API failed after 3 automatic"

    assert FailedTurn.copy("overloaded_error", 0) =~
             "Anthropic's API failed (\"overloaded_error\")"
  end

  test "a harness launch that failed on a full disk says so" do
    copy = SessionManager.compaction_restart_failed_copy(%{}, {:disk_full, @enospc})
    assert copy =~ "disk is full"
    refute copy =~ "compaction"
  end
end
