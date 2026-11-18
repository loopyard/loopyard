defmodule LoopyardWeb.Live.WorkspaceLive.Components.ContextPanelTest do
  use ExUnit.Case, async: true

  alias LoopyardWeb.Live.WorkspaceLive.Components.ContextPanel

  describe "format_number/1" do
    test "formats small numbers as-is" do
      assert ContextPanel.compact_number(0) == "0"
      assert ContextPanel.compact_number(42) == "42"
      assert ContextPanel.compact_number(999) == "999"
    end

    test "formats thousands with K suffix" do
      assert ContextPanel.compact_number(1_000) == "1.0K"
      assert ContextPanel.compact_number(1_500) == "1.5K"
      assert ContextPanel.compact_number(42_000) == "42.0K"
      # 999_999 is just under 1M so it gets K suffix
      result = ContextPanel.compact_number(999_999)
      assert result =~ "K"
    end

    test "formats millions with M suffix" do
      assert ContextPanel.compact_number(1_000_000) == "1.0M"
      assert ContextPanel.compact_number(2_500_000) == "2.5M"
    end

    test "handles floats" do
      assert ContextPanel.compact_number(1500.7) == "1.5K"
    end

    test "handles nil/other" do
      assert ContextPanel.compact_number(nil) == "0"
    end
  end

  describe "docker_ctx/1" do
    test "container agent without bind_mount" do
      agent = %{workspace_id: "abc1", bind_mount: nil}
      ctx = ContextPanel.docker_ctx(agent)

      # Nothing is running in the test env, so the panel names the container
      # the next tool call would boot — the WorkContainer — via the owning
      # module, never a hand-built "loopyard-<id>-…" string.
      assert ctx.container == Loopyard.Workspace.WorkContainer.container_name("abc1")
      assert ctx.volume == Loopyard.VolumeManager.code_volume_name("abc1")
      assert ctx.mode == :container
      assert ctx.workspace_id == "abc1"
    end

    test "bind_mount agent" do
      agent = %{workspace_id: "abc1", bind_mount: "/some/path"}
      ctx = ContextPanel.docker_ctx(agent)

      assert ctx.mode == :bind_mount
      assert ctx.container == Loopyard.Workspace.WorkContainer.container_name("abc1")
    end

    test "agent without workspace_id" do
      agent = %{workspace_id: nil, bind_mount: nil}
      ctx = ContextPanel.docker_ctx(agent)

      assert ctx.container == nil
      assert ctx.volume == nil
      assert ctx.mode == :container
    end
  end

  # NOTE: `mcp_tool_names/0` and the context panel's "Tools" section were
  # removed in the sidebar redesign — the transcript already shows every tool
  # call, so listing the tool inventory in the detail pane was redundant noise.
  # The tool wiring itself is covered by ChatAgent.ToolConfig tests.

  describe "short_tool/1" do
    test "strips MCP server prefix" do
      assert ContextPanel.short_tool("mcp__loopyard-container__exec") == "exec"
      assert ContextPanel.short_tool("mcp__loopyard-agents__list_agents") == "list_agents"
    end

    test "passes non-MCP names through" do
      assert ContextPanel.short_tool("Bash") == "Bash"
      assert ContextPanel.short_tool("Read") == "Read"
    end
  end

  describe "short_model/1" do
    test "a Claude id reads as its marketing name, with no table to keep current" do
      assert ContextPanel.short_model("claude-fable-5-2") == "Fable 5.2"
      assert ContextPanel.short_model("claude-opus-5-5") == "Opus 5.5"
      assert ContextPanel.short_model("claude-sonnet-5-5") == "Sonnet 5.5"
      assert ContextPanel.short_model("claude-haiku-5-5") == "Haiku 5.5"
      assert ContextPanel.short_model("claude-opus-5") == "Opus 5"
      assert ContextPanel.short_model("claude-opus-4-8") == "Opus 4.8"
      assert ContextPanel.short_model("claude-haiku-4-5-20251001") == "Haiku 4.5"
      assert ContextPanel.short_model("claude-sonnet-4-20250514") == "Sonnet 4"
      # A release that does not exist yet needs no code change.
      assert ContextPanel.short_model("claude-opus-6") == "Opus 6"
    end

    test "anything else passes through, minus the prefix and a trailing date" do
      assert ContextPanel.short_model("claude-3-5-sonnet-20241022") == "3-5-sonnet"
      assert ContextPanel.short_model("Sonnet 4.5") == "Sonnet 4.5"
      assert ContextPanel.short_model("gpt-5.6") == "gpt-5.6"
      assert ContextPanel.short_model("default") == "Adapter default"
    end

    test "handles nil" do
      assert ContextPanel.short_model(nil) == nil
    end

    test "handles unknown model strings" do
      assert ContextPanel.short_model("gpt-4") == "gpt-4"
    end
  end
end
