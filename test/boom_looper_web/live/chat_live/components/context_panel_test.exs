defmodule BoomLooperWeb.Live.ChatLive.Components.ContextPanelTest do
  use ExUnit.Case, async: true

  alias BoomLooperWeb.Live.ChatLive.Components.ContextPanel

  describe "format_number/1" do
    test "formats small numbers as-is" do
      assert ContextPanel.format_number(0) == "0"
      assert ContextPanel.format_number(42) == "42"
      assert ContextPanel.format_number(999) == "999"
    end

    test "formats thousands with K suffix" do
      assert ContextPanel.format_number(1_000) == "1.0K"
      assert ContextPanel.format_number(1_500) == "1.5K"
      assert ContextPanel.format_number(42_000) == "42.0K"
      # 999_999 is just under 1M so it gets K suffix
      result = ContextPanel.format_number(999_999)
      assert result =~ "K"
    end

    test "formats millions with M suffix" do
      assert ContextPanel.format_number(1_000_000) == "1.0M"
      assert ContextPanel.format_number(2_500_000) == "2.5M"
    end

    test "handles floats" do
      assert ContextPanel.format_number(1500.7) == "1.5K"
    end

    test "handles nil/other" do
      assert ContextPanel.format_number(nil) == "0"
    end
  end

  describe "docker_ctx/1" do
    test "container agent without bind_mount" do
      agent = %{workspace_id: "abc1", bind_mount: nil}
      ctx = ContextPanel.docker_ctx(agent)

      assert ctx.container == "bl-abc1-workspace-1"
      assert ctx.volume == "bl-abc1-code"
      assert ctx.mode == :container
      assert ctx.workspace_id == "abc1"
    end

    test "bind_mount agent" do
      agent = %{workspace_id: "abc1", bind_mount: "/some/path"}
      ctx = ContextPanel.docker_ctx(agent)

      assert ctx.mode == :bind_mount
      assert ctx.container == "bl-abc1-workspace-1"
    end

    test "agent without workspace_id" do
      agent = %{workspace_id: nil, bind_mount: nil}
      ctx = ContextPanel.docker_ctx(agent)

      assert ctx.container == nil
      assert ctx.volume == nil
      assert ctx.mode == :container
    end
  end

  describe "mcp_tool_names/0" do
    test "returns sorted list of tool names" do
      tools = ContextPanel.mcp_tool_names()

      assert is_list(tools)
      assert length(tools) > 0
      assert "exec" in tools
      assert "write_file" in tools
      assert "docker_compose" in tools

      # Sorted
      assert tools == Enum.sort(tools)
    end

    test "includes tools from all servers" do
      tools = ContextPanel.mcp_tool_names()

      # Container tools
      assert "exec" in tools
      assert "read_file" in tools

      # Agent tools
      assert "list_agents" in tools

      # Secret tools
      assert "list_secrets" in tools
    end
  end
end
