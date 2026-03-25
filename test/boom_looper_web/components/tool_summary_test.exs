defmodule BoomLooperWeb.Components.ToolSummaryTest do
  use ExUnit.Case

  alias BoomLooperWeb.Components.ToolSummary

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
               "Edited /workspace/lib/app.ex"
    end

    test "Bash tool shows command" do
      assert ToolSummary.summarize("Bash", %{"command" => "git status"}) == "$ git status"
    end

    test "Grep tool shows search pattern" do
      assert ToolSummary.summarize("Grep", %{"pattern" => "def hello"}) ==
               "Searched for \"def hello\""
    end

    test "Glob tool shows pattern" do
      assert ToolSummary.summarize("Glob", %{"pattern" => "**/*.rb"}) ==
               "Found files matching **/*.rb"
    end

    test "Agent tool shows prompt snippet" do
      assert ToolSummary.summarize("Agent", %{"prompt" => "Find all test files"}) ==
               "Spawned agent: Find all test files"
    end

    # --- New tool summaries ---

    test "ToolSearch shows query" do
      assert ToolSummary.summarize("ToolSearch", %{"query" => "database migration"}) ==
               "Searching for tools: database migration"
    end

    test "WebSearch shows query" do
      assert ToolSummary.summarize("WebSearch", %{"query" => "watchman arm64 linux install"}) ==
               "Web search: watchman arm64 linux install"
    end

    test "WebFetch shows URL" do
      assert ToolSummary.summarize("WebFetch", %{"url" => "https://example.com/docs"}) ==
               "Fetching https://example.com/docs"
    end

    # --- Container tools ---

    test "exec shows command" do
      assert ToolSummary.summarize("mcp__boom-looper-container__exec", %{"command" => "ls -la"}) ==
               "container $ ls -la"
    end

    test "exec_stream shows command" do
      assert ToolSummary.summarize("mcp__boom-looper-container__exec_stream", %{"command" => "npm install"}) ==
               "container $ npm install"
    end

    test "logs tool" do
      assert ToolSummary.summarize("mcp__boom-looper-container__logs", %{}) ==
               "Checked container logs"
    end

    test "service_status tool" do
      assert ToolSummary.summarize("mcp__boom-looper-container__service_status", %{}) ==
               "Checked service status"
    end

    test "service_containers tool" do
      assert ToolSummary.summarize("mcp__boom-looper-container__service_containers", %{}) ==
               "Service containers"
    end

    # --- Workspace tools ---

    test "set_dockerfile tool" do
      assert ToolSummary.summarize("mcp__boom-looper-workspace__set_dockerfile", %{"dockerfile" => "FROM ruby:3.4"}) ==
               "Updated Dockerfile"
    end

    test "set_dev_command with command" do
      assert ToolSummary.summarize("mcp__boom-looper-workspace__set_dev_command", %{"command" => "bin/dev"}) ==
               "Dev command: bin/dev"
    end

    test "add_service shows name" do
      assert ToolSummary.summarize("mcp__boom-looper-workspace__add_service", %{"name" => "postgres"}) ==
               "Added service: postgres"
    end

    test "rebuild tool" do
      assert ToolSummary.summarize("mcp__boom-looper-workspace__rebuild", %{}) ==
               "Rebuilding..."
    end

    # --- Agent tools ---

    test "spawn_agent shows name" do
      assert ToolSummary.summarize("mcp__boom-looper-agents__spawn_agent", %{"name" => "helper"}) ==
               "Spawned agent helper"
    end

    test "stop_agent shows truncated id" do
      assert ToolSummary.summarize("mcp__boom-looper-agents__stop_agent", %{"agent_id" => "abc123def456"}) ==
               "Stopped agent abc123def"
    end

    # --- MCP prefix stripping ---

    test "strips mcp__ prefix from tool names" do
      assert ToolSummary.summarize("mcp__boom-looper-workspace__start_services", %{}) ==
               "Started services"
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
