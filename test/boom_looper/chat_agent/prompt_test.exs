defmodule BoomLooper.ChatAgent.PromptTest do
  use ExUnit.Case

  alias BoomLooper.ChatAgent.Prompt

  describe "build_system_prompt/2" do
    test "default agent (coding) includes agent ID and container info" do
      prompt = Prompt.build_system_prompt("test-id", bind_mount: "/tmp/project")
      assert prompt =~ "test-id"
      assert prompt =~ "boom-looper-container"
      assert prompt =~ "coding agent"
    end

    test "setup agent includes setup-specific body and catalog" do
      prompt = Prompt.build_system_prompt("test-id", agent_type: "setup", bind_mount: "/tmp/project")
      assert prompt =~ "Setup agent"
      assert prompt =~ "setup_guide.md"
      # Catalog enumerates real files in the folder
      assert prompt =~ "stacks/"
    end

    test "coding agent has a small definition (fits comfortably in system prompt)" do
      prompt = Prompt.build_system_prompt("test-id", agent_type: "coding", bind_mount: "/tmp/project")
      assert String.length(prompt) <= 3500
    end

    test "setup agent prompt stays under CLI argument limit" do
      prompt = Prompt.build_system_prompt("test-id", agent_type: "setup", bind_mount: "/tmp/project")
      assert String.length(prompt) <= 3500,
             "Setup prompt is #{String.length(prompt)} chars, max is 3500."
    end

    test "container agent prompt with workspace stays under limit" do
      workspace = %BoomLooper.Workspace{
        name: "test-project",
        system_prompt: "This is a Rails app.",
        git_url: nil,
        branch: nil
      }

      prompt =
        Prompt.build_system_prompt("test-id",
          bind_mount: "/tmp/project",
          workspace_id: "abcd",
          workspace: workspace,
          agent_type: "coding"
        )

      assert prompt =~ "test-project"
      assert prompt =~ "Rails app"
      assert String.length(prompt) <= 3500
    end

    test "container agent with service stays under limit" do
      workspace = %BoomLooper.Workspace{
        name: "test-project",
        system_prompt: "Rails app with postgres.",
        git_url: nil,
        branch: nil
      }

      prompt =
        Prompt.build_system_prompt("test-id",
          bind_mount: "/tmp/project",
          workspace_id: "abcd",
          workspace: workspace,
          service_name: "postgres",
          agent_type: "coding"
        )

      assert String.length(prompt) <= 3500
    end

    test "service agent prompt includes service name and container" do
      workspace = %BoomLooper.Workspace{
        name: "test-project",
        system_prompt: nil,
        git_url: nil,
        branch: nil
      }

      prompt =
        Prompt.build_system_prompt("test-id",
          workspace_id: "ws-123",
          workspace: workspace,
          service_name: "redis",
          agent_type: "coding"
        )

      assert prompt =~ "redis"
      assert prompt =~ "Service agent"
    end

    test "unknown agent_type falls back to base prompt without crashing" do
      prompt = Prompt.build_system_prompt("test-id", agent_type: "nonexistent", bind_mount: "/tmp")
      # Still includes the base prompt with the agent id
      assert prompt =~ "test-id"
      assert prompt =~ "boom-looper-container"
    end
  end

  describe "base_prompt/3" do
    test "includes agent ID and MCP tool instructions" do
      prompt = Prompt.base_prompt("agent-99", nil, "ws-abc")
      assert prompt =~ "agent-99"
      assert prompt =~ "boom-looper-container"
      assert prompt =~ "Docker volume"
    end
  end

  describe "workspace_prompt/1" do
    test "includes workspace name" do
      workspace = %BoomLooper.Workspace{name: "my-project", system_prompt: nil, git_url: nil, branch: nil}
      prompt = Prompt.workspace_prompt(workspace)
      assert prompt =~ "my-project"
    end

    test "includes custom system prompt when set" do
      workspace = %BoomLooper.Workspace{name: "my-project", system_prompt: "Use Ruby 3.3", git_url: nil, branch: nil}
      prompt = Prompt.workspace_prompt(workspace)
      assert prompt =~ "Use Ruby 3.3"
    end

    test "nil workspace returns empty string" do
      assert Prompt.workspace_prompt(nil) == ""
    end
  end

  describe "service_prompt/2" do
    test "includes service name and container name" do
      prompt = Prompt.service_prompt("redis", "ws-abc")
      assert prompt =~ "redis"
      assert prompt =~ "Service agent"
    end

    test "empty when service or workspace is nil" do
      assert Prompt.service_prompt(nil, "ws-abc") == ""
      assert Prompt.service_prompt("redis", nil) == ""
    end
  end
end
