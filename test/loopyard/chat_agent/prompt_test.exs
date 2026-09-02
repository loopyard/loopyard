defmodule Loopyard.ChatAgent.PromptTest do
  use ExUnit.Case

  alias Loopyard.ChatAgent.Prompt

  # Growth tripwire, not a hard CLI limit (ARG_MAX is orders of magnitude
  # higher). Re-baselined 6000 → 7000 in Jul 2026 after deliberate feature
  # copy landed (git-as-a-tool guidance, questions round-trip); 7000 → 7200 in
  # Sep 2026 for chat attachments (one line telling the agent to open the
  # `📎 Attached:` path). If a change trips this, decide: is the growth bought
  # intentionally? Then re-baseline with a note. Otherwise trim the prompt.
  @prompt_budget 7200

  describe "build_system_prompt/2" do
    test "default agent includes agent ID, container info, and the unified body" do
      prompt = Prompt.build_system_prompt("test-id", bind_mount: "/tmp/project")
      assert prompt =~ "test-id"
      assert prompt =~ "loopyard-container"
      # The one self-determining agent tells itself to assess before acting.
      assert prompt =~ "service_containers"
    end

    test "unified agent carries the setup playbook in its catalog" do
      prompt =
        Prompt.build_system_prompt("test-id", bind_mount: "/tmp/project")

      assert prompt =~ "setup_guide.md"
      # Catalog enumerates real files in the folder
      assert prompt =~ "stacks/"
    end

    test "coding agent has a small definition (fits comfortably in system prompt)" do
      prompt =
        Prompt.build_system_prompt("test-id", bind_mount: "/tmp/project")

      assert String.length(prompt) <= @prompt_budget
    end

    test "setup agent prompt stays under CLI argument limit" do
      prompt =
        Prompt.build_system_prompt("test-id", bind_mount: "/tmp/project")

      assert String.length(prompt) <= @prompt_budget,
             "Setup prompt is #{String.length(prompt)} chars, max is #{@prompt_budget}."
    end

    test "container agent prompt with workspace stays under limit" do
      workspace = %Loopyard.Workspace{
        name: "test-project",
        system_prompt: "This is a Rails app.",
        git_url: nil,
        branch: nil
      }

      prompt =
        Prompt.build_system_prompt("test-id",
          bind_mount: "/tmp/project",
          workspace_id: "abcd",
          workspace: workspace
        )

      assert prompt =~ "test-project"
      assert prompt =~ "Rails app"
      assert String.length(prompt) <= @prompt_budget
    end

    test "container agent with service stays under limit" do
      workspace = %Loopyard.Workspace{
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
          service_name: "postgres"
        )

      assert String.length(prompt) <= @prompt_budget
    end

    test "service agent prompt includes service name and container" do
      workspace = %Loopyard.Workspace{
        name: "test-project",
        system_prompt: nil,
        git_url: nil,
        branch: nil
      }

      prompt =
        Prompt.build_system_prompt("test-id",
          workspace_id: "ws-123",
          workspace: workspace,
          service_name: "redis"
        )

      assert prompt =~ "redis"
      assert prompt =~ "Service agent"
    end

    test "always includes the single coding agent's definition" do
      prompt = Prompt.build_system_prompt("test-id", bind_mount: "/tmp")

      assert prompt =~ "test-id"
      assert prompt =~ "loopyard-container"
      # the coding agent definition + its file catalog are folded in
      assert prompt =~ "read_agent_file"
    end
  end

  describe "base_prompt/3" do
    test "includes agent ID and MCP tool instructions" do
      prompt = Prompt.base_prompt("agent-99", nil, "ws-abc")
      assert prompt =~ "agent-99"
      assert prompt =~ "loopyard-container"
      assert prompt =~ "Docker volume"
    end
  end

  describe "workspace_prompt/1" do
    test "includes workspace name" do
      workspace = %Loopyard.Workspace{
        name: "my-project",
        system_prompt: nil,
        git_url: nil,
        branch: nil
      }

      prompt = Prompt.workspace_prompt(workspace)
      assert prompt =~ "my-project"
    end

    test "includes custom system prompt when set" do
      workspace = %Loopyard.Workspace{
        name: "my-project",
        system_prompt: "Use Ruby 3.3",
        git_url: nil,
        branch: nil
      }

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
