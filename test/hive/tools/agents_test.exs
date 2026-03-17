defmodule Hive.Tools.AgentsTest do
  use ExUnit.Case

  alias Hive.Tools.Agents

  test "module is a valid MCP server" do
    assert ClaudeCode.MCP.Server.sdk_server?(Agents)
  end

  test "exports tool server info with correct name" do
    info = Agents.__tool_server__()
    assert info.name == "hive-agents"
    assert is_list(info.tools)
    assert length(info.tools) == 4
  end

  test "tool modules have expected names" do
    info = Agents.__tool_server__()
    tool_names = Enum.map(info.tools, & &1.__tool_name__())
    assert "list_agents" in tool_names
    assert "spawn_agent" in tool_names
    assert "send_message_to_agent" in tool_names
    assert "stop_agent" in tool_names
  end
end
