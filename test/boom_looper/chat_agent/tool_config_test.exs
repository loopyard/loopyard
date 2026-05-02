defmodule BoomLooper.ChatAgent.ToolConfigTest do
  use ExUnit.Case

  alias BoomLooper.ChatAgent.ToolConfig

  describe "default_tools/0" do
    test "returns a list of tool modules" do
      tools = ToolConfig.default_tools()
      assert is_list(tools)
      assert length(tools) > 0

      for mod <- tools do
        assert is_atom(mod)
        # Ensure module is loaded, then check it implements __tool_server__
        Code.ensure_loaded!(mod)
        assert function_exported?(mod, :__tool_server__, 0)
      end
    end

    test "includes expected tool modules" do
      tools = ToolConfig.default_tools()
      assert BoomLooper.Tools.Container in tools
      assert BoomLooper.Tools.Secrets in tools
    end

    test "does NOT include the Agents toolkit (workspace boundary)" do
      tools = ToolConfig.default_tools()

      refute Code.ensure_loaded?(BoomLooper.Tools.Agents),
             "Tools.Agents should be deleted, not just unlinked"

      refute Enum.any?(tools, &(&1 == BoomLooper.Tools.Agents))
    end

    test "container toolkit does NOT expose raw `docker` CLI tool" do
      info = BoomLooper.Tools.Container.__tool_server__()
      tool_names = Enum.map(info.tools, & &1.__tool_name__())
      refute "docker" in tool_names

      refute Code.ensure_loaded?(BoomLooper.Tools.Container.Docker),
             "Tools.Container.Docker should be deleted, not just unlinked"
    end
  end

  describe "build_mcp_servers/2" do
    test "builds a map from tool modules with empty assigns when no agent_id" do
      tools = ToolConfig.default_tools()
      servers = ToolConfig.build_mcp_servers(tools)
      assert is_map(servers)
      assert map_size(servers) == length(tools)

      for {name, config} <- servers do
        assert is_binary(name) or is_atom(name)
        assert %{module: mod, assigns: %{}} = config
        assert mod in tools
      end
    end

    test "threads agent_id into every server's assigns" do
      tools = ToolConfig.default_tools()
      servers = ToolConfig.build_mcp_servers(tools, "agent-abc")

      for {_name, config} <- servers do
        assert %{module: _, assigns: %{agent_id: "agent-abc"}} = config
      end
    end
  end

  describe "build_allowed_tools/2" do
    test "bind-mount agents get Read, Glob, Grep" do
      tools = ToolConfig.default_tools()
      allowed = ToolConfig.build_allowed_tools(tools, false)
      assert "Read" in allowed
      assert "Glob" in allowed
      assert "Grep" in allowed
    end

    test "container-only agents do NOT get Read, Glob, Grep" do
      tools = ToolConfig.default_tools()
      allowed = ToolConfig.build_allowed_tools(tools, true)
      refute "Read" in allowed
      refute "Glob" in allowed
      refute "Grep" in allowed
    end

    test "both agent types get WebSearch and WebFetch" do
      tools = ToolConfig.default_tools()

      for container_only? <- [true, false] do
        allowed = ToolConfig.build_allowed_tools(tools, container_only?)
        assert "WebSearch" in allowed
        assert "WebFetch" in allowed
      end
    end

    test "includes MCP tool names from modules" do
      tools = ToolConfig.default_tools()
      allowed = ToolConfig.build_allowed_tools(tools, false)
      mcp_tools = Enum.filter(allowed, &String.starts_with?(&1, "mcp__"))
      assert length(mcp_tools) > 0
    end
  end

  describe "denied_native_tools_for_container_agents/0" do
    test "includes Bash and filesystem tools" do
      denied = ToolConfig.denied_native_tools_for_container_agents()
      assert "Bash" in denied
      assert "Edit" in denied
      assert "Write" in denied
      assert "Read" in denied
    end
  end
end
