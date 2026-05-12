defmodule Loopyard.StateKeeperTest do
  use ExUnit.Case, async: false

  describe "init/1" do
    test "ensures all required ETS tables exist" do
      # StateKeeper is already started by the application supervisor.
      # Verify the tables it's responsible for exist.
      assert :ets.whereis(:chat_agents) != :undefined
      assert :ets.whereis(:project_registry) != :undefined
      assert :ets.whereis(:event_log) != :undefined
    end

    test "tables survive after StateKeeper init" do
      # Write to each table and verify data persists
      Loopyard.EventLog.info("test", "state keeper test")
      events = Loopyard.EventLog.recent()
      assert Enum.any?(events, &(&1.message == "state keeper test"))
    end
  end
end
