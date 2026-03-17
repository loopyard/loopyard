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
      path = Path.join(System.tmp_dir!(), "hive_test_file_#{:rand.uniform(100_000)}")
      File.write!(path, "test")

      try do
        assert {:error, "Path exists but is not a directory"} = HiveAgent.validate_working_dir(path)
      after
        File.rm(path)
      end
    end
  end

  describe "agent lifecycle" do
    test "list_agents returns a list" do
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
end
