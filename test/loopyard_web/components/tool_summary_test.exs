defmodule LoopyardWeb.Components.ToolSummaryTest do
  use ExUnit.Case, async: true

  alias LoopyardWeb.Components.ToolSummary

  describe "summarize/2" do
    # --- Claude Code built-in tools ---

    test "Read tool shows file path" do
      assert ToolSummary.summarize("Read", %{"file_path" => "/workspace/app/models/user.rb"}) ==
               "Read /workspace/app/models/user.rb"
    end

    test "Write tool shows file path" do
      assert ToolSummary.summarize("Write", %{"file_path" => "/workspace/config.yml"}) ==
               "Wrote /workspace/config.yml"
    end

    test "Edit tool shows file path" do
      assert ToolSummary.summarize("Edit", %{"file_path" => "/workspace/lib/app.ex"}) ==
               "Update /workspace/lib/app.ex"
    end

    test "Bash tool shows command" do
      assert ToolSummary.summarize("Bash", %{"command" => "git status"}) == "$ git status"
    end

    test "Grep tool shows search pattern" do
      assert ToolSummary.summarize("Grep", %{"pattern" => "def hello"}) ==
               "grep \"def hello\""
    end

    test "Glob tool shows pattern" do
      assert ToolSummary.summarize("Glob", %{"pattern" => "**/*.rb"}) ==
               "glob **/*.rb"
    end

    test "Agent tool shows prompt snippet" do
      assert ToolSummary.summarize("Agent", %{"prompt" => "Find all test files"}) ==
               "Spawned agent: Find all test files"
    end

    # --- New tool summaries ---

    test "ToolSearch shows human-readable message" do
      assert ToolSummary.summarize("ToolSearch", %{"query" => "database migration"}) ==
               "Loading tools"
    end

    test "WebSearch shows query" do
      assert ToolSummary.summarize("WebSearch", %{"query" => "watchman arm64 linux install"}) ==
               "Search: watchman arm64 linux install"
    end

    test "WebFetch shows URL" do
      assert ToolSummary.summarize("WebFetch", %{"url" => "https://example.com/docs"}) ==
               "Fetch https://example.com/docs"
    end

    # --- Container tools ---

    test "exec shows command" do
      assert ToolSummary.summarize("mcp__loopyard-container__exec", %{"command" => "ls -la"}) ==
               "$ ls -la"
    end

    test "logs tool" do
      assert ToolSummary.summarize("mcp__loopyard-container__logs", %{}) == "Read logs"

      assert ToolSummary.summarize("mcp__loopyard-container__logs", %{"service" => "web"}) ==
               "Read logs (web)"
    end

    test "service_status tool reads as a verb+object" do
      assert ToolSummary.summarize("mcp__loopyard-container__service_status", %{}) ==
               "Check service status"
    end

    test "service_containers tool reads as a verb+object" do
      assert ToolSummary.summarize("mcp__loopyard-container__service_containers", %{}) ==
               "List service containers"
    end

    test "app_url reads as a real action, not a bare noun" do
      assert ToolSummary.summarize("mcp__loopyard-container__app_url", %{}) == "Get preview URL"

      assert ToolSummary.summarize("mcp__loopyard-container__app_url", %{"service" => "dev"}) ==
               "Get preview URL (dev)"
    end

    test "workspace_info / ports / inspect_env read as actions" do
      assert ToolSummary.summarize("mcp__loopyard-container__workspace_info", %{}) ==
               "Read workspace info"

      assert ToolSummary.summarize("mcp__loopyard-container__ports", %{}) == "List ports"

      assert ToolSummary.summarize("mcp__loopyard-container__inspect_env", %{}) == "Read env vars"
    end

    # --- Workspace tools ---

    test "set_dockerfile tool" do
      assert ToolSummary.summarize("mcp__loopyard-workspace__set_dockerfile", %{
               "dockerfile" => "FROM ruby:3.4"
             }) ==
               "Update Dockerfile"
    end

    test "set_dev_command" do
      assert ToolSummary.summarize("mcp__loopyard-workspace__set_dev_command", %{
               "command" => "bin/dev"
             }) ==
               "Set dev command"
    end

    test "add_service shows name" do
      assert ToolSummary.summarize("mcp__loopyard-workspace__add_service", %{
               "name" => "postgres"
             }) ==
               "Add service postgres"
    end

    test "rebuild tool" do
      assert ToolSummary.summarize("mcp__loopyard-workspace__rebuild", %{}) == "Rebuild"
    end

    # --- Agent tools ---

    test "spawn_agent shows name" do
      assert ToolSummary.summarize("mcp__loopyard-agents__spawn_agent", %{"name" => "helper"}) ==
               "Spawned agent helper"
    end

    test "stop_agent shows truncated id" do
      assert ToolSummary.summarize("mcp__loopyard-agents__stop_agent", %{
               "agent_id" => "abc123def456"
             }) ==
               "Stopped agent abc123def"
    end

    # --- MCP prefix stripping ---

    test "strips mcp__ prefix from tool names" do
      assert ToolSummary.summarize("mcp__loopyard-workspace__start_services", %{}) ==
               "Start services"
    end

    # --- Fallbacks ---

    test "unknown tool gets humanized name" do
      assert ToolSummary.summarize("some_custom_tool", %{}) == "Some custom tool"
    end

    test "non-map input returns raw tool name" do
      assert ToolSummary.summarize("SomeTool", nil) == "SomeTool"
    end

    # --- Truncation ---

    test "long commands get truncated" do
      long_cmd = String.duplicate("x", 200)
      result = ToolSummary.summarize("Bash", %{"command" => long_cmd})
      assert String.length(result) < 200
    end

    test "long search queries get truncated" do
      long_query = String.duplicate("word ", 50)
      result = ToolSummary.summarize("WebSearch", %{"query" => long_query})
      assert String.length(result) < 100
    end
  end
end
