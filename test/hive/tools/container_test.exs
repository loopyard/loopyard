defmodule Hive.Tools.ContainerTest do
  use ExUnit.Case

  alias Hive.Tools.Container

  test "module is a valid MCP server" do
    assert ClaudeCode.MCP.Server.sdk_server?(Container)
  end

  test "exports tool server info with correct name" do
    info = Container.__tool_server__()
    assert info.name == "hive-container"
    assert is_list(info.tools)
    assert length(info.tools) == 6
  end

  test "tool modules have expected names" do
    info = Container.__tool_server__()
    tool_names = Enum.map(info.tools, & &1.__tool_name__())
    assert "create" in tool_names
    assert "exec" in tool_names
    assert "copy_in" in tool_names
    assert "copy_out" in tool_names
    assert "stop" in tool_names
    assert "list" in tool_names
  end
end
