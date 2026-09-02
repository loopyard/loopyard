defmodule Loopyard.ChatAgent.PromptTest do
  use ExUnit.Case

  alias Loopyard.Agents.Template
  alias Loopyard.ChatAgent.Prompt

  # Growth tripwire, not a hard limit (the brief travels as a file, not a CLI
  # arg). Re-baselined 7200 → 9500 in Sep 2026 when the shared decisions
  # doctrine (memos, THE READER IS STATELESS) moved out of the operator's
  # override and into the block every agent gets. If a change trips this,
  # decide: is the growth bought intentionally? Then re-baseline with a note.
  @prompt_budget 9500

  describe "build_system_prompt/2 — the coding template (default)" do
    test "includes agent ID, container info, and the unified body" do
      prompt = Prompt.build_system_prompt("test-id", workspace_id: "ws-1")
      assert prompt =~ "test-id"
      assert prompt =~ "Workspace: ws-1"
      assert prompt =~ "loopyard-container"
      # The one self-determining agent tells itself to assess before acting.
      assert prompt =~ "service_containers"
    end

    test "carries the setup playbook in its catalog" do
      prompt = Prompt.build_system_prompt("test-id", [])
      assert prompt =~ "setup_guide.md"
      assert prompt =~ "stacks/"
      assert prompt =~ "read_agent_file"
    end

    test "the shared decisions doctrine appears exactly once" do
      prompt = Prompt.build_system_prompt("test-id", [])
      assert length(String.split(prompt, "THE READER IS STATELESS")) == 2
      assert prompt =~ "request_secret"
    end

    test "stays under the growth tripwire" do
      workspace = %Loopyard.Workspace{
        name: "test-project",
        system_prompt: "Rails app with postgres.",
        git_url: nil,
        branch: nil
      }

      prompt =
        Prompt.build_system_prompt("test-id",
          workspace_id: "abcd",
          workspace: workspace,
          service_name: "postgres"
        )

      assert prompt =~ "test-project"
      assert prompt =~ "Rails app"
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
  end

  describe "build_system_prompt/2 — the system template" do
    test "composes facts + shared blocks + the system body, no workspace doctrine" do
      prompt =
        Prompt.build_system_prompt("op-1",
          template: Template.system(),
          name: "Operator",
          workstation_identity: "brad"
        )

      assert prompt =~ "YOUR AGENT ID: op-1"
      assert prompt =~ "You are Operator, a system agent (workstation brad)"
      assert prompt =~ "recall_conversation"
      assert prompt =~ "dispatch(target, message)"
      assert prompt =~ "END EVERY TURN BY CALLING"
      assert prompt =~ "THE READER IS STATELESS"
      refute prompt =~ "the code is at /workspace"
      refute prompt =~ "propose_fork"
      assert String.length(prompt) <= 16_000
    end

    test "template_id selects the template too" do
      prompt = Prompt.build_system_prompt("op-2", template_id: "system")
      assert prompt =~ "system agent"
    end
  end

  describe "workspace_prompt/1" do
    test "includes workspace name and custom system prompt" do
      workspace = %Loopyard.Workspace{
        name: "my-project",
        system_prompt: "Use Ruby 3.3",
        git_url: nil,
        branch: nil
      }

      prompt = Prompt.workspace_prompt(workspace)
      assert prompt =~ "my-project"
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
