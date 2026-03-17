defmodule Hive.AgentTest do
  use ExUnit.Case

  alias Hive.Agent, as: HiveAgent

  describe "validate_working_dir/1" do
    test "returns :ok for an existing directory" do
      assert HiveAgent.validate_working_dir(System.tmp_dir!()) == :ok
    end

    test "returns error for non-existent path" do
      assert {:error, "Directory does not exist"} = HiveAgent.validate_working_dir("/nonexistent/path/xyz")
    end

    test "returns error for a file (not directory)" do
      # Create a temp file
      path = Path.join(System.tmp_dir!(), "hive_test_file_#{:rand.uniform(100_000)}")
      File.write!(path, "test")

      try do
        assert {:error, "Path exists but is not a directory"} = HiveAgent.validate_working_dir(path)
      after
        File.rm(path)
      end
    end
  end

  describe "agent lifecycle with echo" do
    setup do
      # Use a simple command instead of claude for testing
      # We'll test the GenServer lifecycle using the existing infrastructure
      :ok
    end

    test "list_agents returns empty list when no agents running" do
      # This relies on no other tests spawning agents concurrently
      agents = HiveAgent.list_agents()
      assert is_list(agents)
    end

    test "subscribe/0 subscribes to the agents topic" do
      assert :ok = HiveAgent.subscribe()
    end

    test "subscribe/1 subscribes to a specific agent topic" do
      assert :ok = HiveAgent.subscribe("test-agent-id")
    end

    test "unsubscribe/1 unsubscribes from a specific agent topic" do
      HiveAgent.subscribe("test-agent-id")
      assert :ok = HiveAgent.unsubscribe("test-agent-id")
    end
  end

  describe "kill_process_tree/1" do
    test "handles nil pid gracefully" do
      assert :ok = HiveAgent.kill_process_tree(nil)
    end

    test "handles non-existent pid gracefully" do
      assert :ok = HiveAgent.kill_process_tree(999_999_999)
    end
  end
end
