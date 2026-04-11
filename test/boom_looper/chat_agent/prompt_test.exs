defmodule BoomLooper.ChatAgent.PromptTest do
  use ExUnit.Case

  alias BoomLooper.ChatAgent.Prompt

  describe "build_system_prompt/5" do
    test "setup agent prompt (no workspace) includes agent ID" do
      prompt = Prompt.build_system_prompt("test-id", "/tmp/project", nil, nil, nil)
      assert prompt =~ "test-id"
    end

    test "setup agent prompt stays under CLI argument limit" do
      prompt = Prompt.build_system_prompt("test-id", "/tmp/project", nil, nil, nil)
      assert String.length(prompt) <= 2000,
        "Setup prompt is #{String.length(prompt)} chars, max is 2000."
    end

    test "container agent prompt includes workspace info" do
      workspace = %BoomLooper.Workspace{
        name: "test-project",
        system_prompt: "This is a Rails app.",
        git_url: nil,
        branch: nil
      }

      prompt = Prompt.build_system_prompt("test-id", "/tmp/project", "abcd", workspace, nil)
      assert prompt =~ "test-project"
      assert prompt =~ "Rails app"
    end

    test "container agent prompt stays under limit" do
      workspace = %BoomLooper.Workspace{
        name: "test-project",
        system_prompt: "This is a Rails app.",
        git_url: nil,
        branch: nil
      }

      prompt = Prompt.build_system_prompt("test-id", "/tmp/project", "abcd", workspace, nil)
      assert String.length(prompt) <= 2000,
        "Container prompt is #{String.length(prompt)} chars, max is 2000."
    end

    test "container agent with service stays under limit" do
      workspace = %BoomLooper.Workspace{
        name: "test-project",
        system_prompt: "Rails app with postgres.",
        git_url: nil,
        branch: nil
      }

      prompt = Prompt.build_system_prompt("test-id", "/tmp/project", "abcd", workspace, "postgres")
      assert String.length(prompt) <= 2000,
        "Full prompt is #{String.length(prompt)} chars, max is 2000."
    end

    test "service agent prompt includes service name" do
      workspace = %BoomLooper.Workspace{
        name: "test-project",
        system_prompt: nil,
        git_url: nil,
        branch: nil
      }

      prompt = Prompt.build_system_prompt("test-id", nil, "ws-123", workspace, "redis")
      assert prompt =~ "redis"
      assert prompt =~ "Service agent"
    end
  end

  describe "setup_base_prompt/2" do
    test "includes agent ID and tool instructions" do
      prompt = Prompt.setup_base_prompt("agent-42", nil)
      assert prompt =~ "agent-42"
      assert prompt =~ "write_file"
      assert prompt =~ "docker_compose"
    end
  end

  describe "container_base_prompt/3" do
    test "includes agent ID and MCP tool instructions" do
      prompt = Prompt.container_base_prompt("agent-99", nil, "ws-abc")
      assert prompt =~ "agent-99"
      assert prompt =~ "boom-looper-container"
      assert prompt =~ "Docker volume"
    end
  end

  describe "workspace_prompt/2" do
    test "includes workspace name" do
      workspace = %BoomLooper.Workspace{name: "my-project", system_prompt: nil, git_url: nil, branch: nil}
      prompt = Prompt.workspace_prompt(workspace, nil)
      assert prompt =~ "my-project"
    end

    test "includes custom system prompt when set" do
      workspace = %BoomLooper.Workspace{name: "my-project", system_prompt: "Use Ruby 3.3", git_url: nil, branch: nil}
      prompt = Prompt.workspace_prompt(workspace, nil)
      assert prompt =~ "Use Ruby 3.3"
    end
  end

  describe "setup_prompt/1" do
    test "includes bind_mount path when provided" do
      prompt = Prompt.setup_prompt("/home/user/project")
      assert prompt =~ "/home/user/project"
    end

    test "omits path note when bind_mount is nil" do
      prompt = Prompt.setup_prompt(nil)
      refute prompt =~ " at "
    end
  end

  describe "setup_guide/0" do
    test "returns the setup guide content from priv" do
      guide = Prompt.setup_guide()
      assert is_binary(guide)
      assert String.length(guide) > 0
    end
  end
end
