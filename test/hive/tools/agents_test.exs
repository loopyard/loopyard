defmodule Hive.Tools.AgentsTest do
  use ExUnit.Case

  alias Hive.Tools.Agents

  describe "module structure" do
    test "is a valid MCP server" do
      assert ClaudeCode.MCP.Server.sdk_server?(Agents)
    end

    test "has correct server name and 4 tools" do
      info = Agents.__tool_server__()
      assert info.name == "hive-agents"
      assert length(info.tools) == 4
    end

    test "tool names match expected" do
      tool_names = Agents.__tool_server__().tools |> Enum.map(& &1.__tool_name__())
      assert "list_agents" in tool_names
      assert "spawn_agent" in tool_names
      assert "send_message_to_agent" in tool_names
      assert "stop_agent" in tool_names
    end
  end

  describe "do_list/0" do
    test "returns a list" do
      agents = Agents.do_list()
      assert is_list(agents)
    end
  end

  describe "do_spawn/2" do
    test "spawns an agent and returns id and name" do
      assert {:ok, %{id: id, name: "Test Spawn"}} =
               Agents.do_spawn("Test Spawn", File.cwd!())

      assert is_binary(id)

      # Verify it shows up in list
      agents = Agents.do_list()
      assert Enum.any?(agents, &(&1.id == id))

      # Clean up
      Agents.do_stop(id)
      Process.sleep(100)
    end
  end

  describe "do_stop/1" do
    test "stops a running agent" do
      {:ok, %{id: id}} = Agents.do_spawn("To Stop", File.cwd!())
      assert {:ok, _} = Agents.do_stop(id)
      Process.sleep(100)
    end

    test "returns error for non-existent agent" do
      assert {:error, _} = Agents.do_stop("nonexistent")
    end
  end

  describe "do_send_message/2" do
    test "returns error for non-existent agent" do
      assert {:error, _} = Agents.do_send_message("nonexistent", "hello")
    end
  end
end
