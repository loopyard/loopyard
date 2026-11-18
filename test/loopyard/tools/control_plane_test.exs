defmodule Loopyard.Tools.ControlPlaneTest do
  @moduledoc """
  The operator's control-plane toolkit: toolkit conformance (every tool exports
  the `Loopyard.Tool` interface), dispatch target resolution, and the
  approval-gated delete tools — which must post an Approve/Deny card and WAIT,
  never delete synchronously. No Docker: destructive paths are only driven to
  the pending card and then denied, so nothing is ever torn down.
  """
  use ExUnit.Case, async: false

  alias Loopyard.Tools.ControlPlane
  alias Loopyard.Tools.ControlPlane.{Dispatch, DeleteProject, DeleteWorkspace}
  alias Loopyard.Harness.Approvals

  setup do
    Loopyard.StateKeeper.ensure_tables!()
    :ok
  end

  describe "toolkit" do
    test "has correct server name" do
      info = ControlPlane.__tool_server__()
      assert info.name == "loopyard-control-plane"
    end

    test "includes the cockpit + lifecycle tools" do
      tool_names =
        ControlPlane.__tool_server__().tools |> Enum.map(& &1.__tool_name__()) |> MapSet.new()

      for name <- ~w(overview peek_workspace system_status recent_activity dispatch
                     delete_workspace delete_project) do
        assert name in tool_names, "missing tool: #{name}"
      end
    end

    test "each tool module exports the required interface" do
      for tool_mod <- ControlPlane.__tool_server__().tools do
        # function_exported?/3 returns false for a not-yet-loaded module, so
        # ensure it's loaded first — otherwise this flakes on lazily-loaded
        # tools depending on test order.
        Code.ensure_loaded!(tool_mod)

        assert function_exported?(tool_mod, :__tool_name__, 0),
               "#{tool_mod} missing __tool_name__/0"

        assert function_exported?(tool_mod, :__description__, 0),
               "#{tool_mod} missing __description__/0"

        assert function_exported?(tool_mod, :input_schema, 0),
               "#{tool_mod} missing input_schema/0"

        assert function_exported?(tool_mod, :execute, 2), "#{tool_mod} missing execute/2"

        schema = tool_mod.input_schema()
        assert is_map(schema), "#{tool_mod}.input_schema/0 must return a map"
        assert schema["type"] == "object", "#{tool_mod} schema must have type object"
      end
    end

    test "every tool schema is JSON-serializable (catches sigil/AST leaks)" do
      for tool_mod <- ControlPlane.__tool_server__().tools do
        tool_def = %{
          "name" => tool_mod.__tool_name__(),
          "description" => tool_mod.__description__(),
          "inputSchema" => tool_mod.input_schema()
        }

        assert {:ok, _json} = Jason.encode(tool_def),
               "#{tool_mod} tool definition is not JSON-serializable — " <>
                 "check for unevaluated sigils or AST nodes in params"
      end
    end
  end

  describe "Dispatch target resolution" do
    test "unresolvable target is a clean error naming the target" do
      target = "no-such-target-#{System.unique_integer([:positive])}"

      assert {:error, msg} =
               Dispatch.execute(%{agent_id: "op", target: target, message: "hi"}, %{})

      assert msg =~ target
    end

    test "a workspace with no running agent errors and says so" do
      project_id = register_project("cp-dispatch-#{System.unique_integer([:positive])}")

      ws_id =
        register_workspace(project_id, "cp-dispatch-ws-#{System.unique_integer([:positive])}")

      assert {:error, msg} =
               Dispatch.execute(%{agent_id: "op", target: ws_id, message: "go"}, %{})

      assert msg =~ "no running agent"
    end

    test "non-binary target is rejected cleanly" do
      assert {:error, msg} = Dispatch.execute(%{agent_id: "op", target: 123, message: "hi"}, %{})
      assert msg =~ "target must be"
    end
  end

  describe "a fleet with several agents and several accounts" do
    alias Loopyard.Tools.ControlPlane.{Agent, Overview}

    setup do
      project_id = register_project("cp-fleet-#{System.unique_integer([:positive])}")
      ws_id = register_workspace(project_id, "cp-fleet-ws-#{System.unique_integer([:positive])}")

      # Two agents in ONE workspace (fabricated summaries — pure ETS).
      a = fake_agent(ws_id, "Builder", :idle)
      b = fake_agent(ws_id, "Reviewer", :rate_limited)

      # A second account that can run Claude, and one that can't run anything.
      signed_in = "acct-in-#{System.unique_integer([:positive])}"
      empty = "acct-empty-#{System.unique_integer([:positive])}"
      :ok = Loopyard.Workstation.create(signed_in)
      :ok = Loopyard.Workstation.create(empty)
      :ok = Loopyard.Workstation.Env.put("CLAUDE_CODE_OAUTH_TOKEN", "sk-ant-test", signed_in)

      on_exit(fn ->
        File.rm_rf(Loopyard.Workstation.dir(signed_in))
        File.rm_rf(Loopyard.Workstation.dir(empty))
      end)

      %{ws_id: ws_id, a: a, b: b, signed_in: signed_in, empty: empty}
    end

    test "a workspace with two agents is refused by name and lists their ids", ctx do
      assert {:error, msg} = ControlPlane.resolve_agent(ctx.ws_id)
      assert msg =~ "2 agents"
      assert msg =~ "Builder [#{ctx.a}]"
      assert msg =~ "Reviewer [#{ctx.b}] (rate_limited)"

      # By agent id it's exact — no guess to make.
      assert {:ok, %{id: id}} = ControlPlane.resolve_agent(ctx.b)
      assert id == ctx.b

      # Dispatch inherits the refusal instead of landing on an arbitrary one.
      assert {:error, _} =
               Dispatch.execute(%{agent_id: "op", target: ctx.ws_id, message: "go"}, %{})
    end

    test "overview names each agent by id with what it runs on and who pays", ctx do
      assert {:ok, out} = Overview.execute(%{agent_id: "op"}, %{})
      assert out =~ "Builder [#{ctx.a}] (idle · Claude Code claude-opus-5 · account brad)"
      assert out =~ "Reviewer [#{ctx.b}] (rate_limited"
      # The switch options: which accounts can run which harness.
      assert out =~ "Accounts: "
      assert out =~ "#{ctx.signed_in} — Claude Code"
      assert out =~ "#{ctx.empty} — no harness credential"
    end

    test "overview leads with what needs attention and the move the chief may make", ctx do
      item = Loopyard.Fleet.Conditions.item_id(ctx.a, :interrupted)
      on_exit(fn -> :ets.delete(:notifications, item) end)

      Loopyard.Notifications.raise_item(
        Loopyard.Notifications.Item.stuck(ctx.a, :interrupted, "cut off", %{})
      )

      Loopyard.Notifications.sync()

      assert {:ok, out} = Overview.execute(%{agent_id: "op"}, %{})
      assert String.starts_with?(out, "Needs attention:\n")

      assert out =~
               "- Builder [#{ctx.a}]: Interrupted — you may continue it " <>
                 "(agent action=continue target=#{ctx.a})"
    end

    test "switch moves an agent to an account that can run its harness", ctx do
      assert {:ok, msg} =
               Agent.execute(
                 %{agent_id: "op", target: ctx.b, action: "switch", account: ctx.signed_in},
                 %{}
               )

      assert msg =~ "account #{ctx.signed_in}"
      assert msg =~ "picks its conversation back up"
    end

    test "switch refuses an account that doesn't exist or can't sign that harness in", ctx do
      assert {:error, msg} =
               Agent.execute(
                 %{agent_id: "op", target: ctx.b, action: "switch", account: "nope"},
                 %{}
               )

      assert msg =~ "No account 'nope'"

      assert {:error, msg} =
               Agent.execute(
                 %{agent_id: "op", target: ctx.b, action: "switch", account: ctx.empty},
                 %{}
               )

      assert msg =~ "no Claude Code credential"
      # It says who CAN, so the next call is the right one.
      assert msg =~ ctx.signed_in
    end

    test "switch validates the model selection and needs something to do", ctx do
      assert {:error, msg} =
               Agent.execute(
                 %{agent_id: "op", target: ctx.a, action: "switch", model: "sonnet"},
                 %{}
               )

      assert msg =~ "harness:model"

      assert {:error, msg} =
               Agent.execute(%{agent_id: "op", target: ctx.a, action: "switch"}, %{})

      assert msg =~ "Nothing to switch"

      assert {:ok, msg} =
               Agent.execute(
                 %{
                   agent_id: "op",
                   target: ctx.a,
                   action: "switch",
                   model: "claude:sonnet"
                 },
                 %{}
               )

      assert msg =~ "Claude Code sonnet"
    end

    test "switch sets what an agent's sub-agents run on, validated against its harness", ctx do
      assert {:ok, msg} =
               Agent.execute(
                 %{
                   agent_id: "op",
                   target: ctx.a,
                   action: "switch",
                   subagent_model: "haiku"
                 },
                 %{}
               )

      assert msg =~ "sub-agents on haiku"

      assert {:ok, msg} =
               Agent.execute(
                 %{agent_id: "op", target: ctx.a, action: "switch", subagent_model: "same"},
                 %{}
               )

      assert msg =~ "sub-agents on the agent's own model"

      assert {:error, msg} =
               Agent.execute(
                 %{agent_id: "op", target: ctx.a, action: "switch", subagent_model: "gpt-9"},
                 %{}
               )

      assert msg =~ "subagent_model must be one of"
      assert msg =~ "sonnet"

      # Moving it onto Codex in the same call: Codex has no such knob.
      assert {:error, msg} =
               Agent.execute(
                 %{
                   agent_id: "op",
                   target: ctx.a,
                   action: "switch",
                   model: "codex:default",
                   subagent_model: "sonnet"
                 },
                 %{}
               )

      assert msg =~ "Codex doesn't take a sub-agent model"
    end

    test "overview shows the sub-agent model when one is set", ctx do
      [{_, row}] = :ets.lookup(:chat_agents, ctx.a)
      :ets.insert(:chat_agents, {ctx.a, Map.put(row, :subagent_model, "sonnet")})

      assert {:ok, out} = Overview.execute(%{agent_id: "op"}, %{})

      assert out =~
               "Builder [#{ctx.a}] (idle · Claude Code claude-opus-5 · sub-agents sonnet"

      refute out =~ "Reviewer [#{ctx.b}] (rate_limited · Claude Code claude-opus-5 · sub-agents"
    end

    test "the operator can't switch itself", ctx do
      assert {:error, msg} =
               Agent.execute(
                 %{agent_id: ctx.a, target: ctx.a, action: "switch", account: ctx.signed_in},
                 %{}
               )

      assert msg =~ "operator itself"
    end
  end

  describe "DeleteProject" do
    test "unknown target is a clean error and posts NO approval card" do
      operator_id = "cp-op-#{System.unique_integer([:positive])}"
      target = "no-such-project-#{System.unique_integer([:positive])}"

      assert pending_for(operator_id) == []

      assert {:error, msg} = DeleteProject.execute(%{agent_id: operator_id, target: target}, %{})
      assert msg =~ "No project matched"
      assert pending_for(operator_id) == []
    end

    test "posts a blocking approval card and does NOT delete synchronously; deny keeps the project" do
      operator_id = "cp-op-#{System.unique_integer([:positive])}"
      project_id = register_project("cp-doomed-#{System.unique_integer([:positive])}")

      assert pending_for(operator_id) == []

      task =
        Task.async(fn ->
          DeleteProject.execute(%{agent_id: operator_id, target: project_id}, %{})
        end)

      id = wait_for_pending(operator_id)

      # The proposal is a live blocking approval for this operator…
      assert [{^id, _entry}] = pending_for(operator_id)
      # …and the project is untouched while the human hasn't decided.
      assert %{id: ^project_id} = Loopyard.ProjectRegistry.get_project(project_id)

      assert :ok = Approvals.decide(id, :deny)
      assert {:ok, msg} = Task.await(task, 1_500)
      assert msg =~ "declined"

      # Deny means the project survives, and the pending entry is gone.
      assert %{id: ^project_id} = Loopyard.ProjectRegistry.get_project(project_id)
      assert pending_for(operator_id) == []
    end
  end

  describe "DeleteWorkspace" do
    test "unknown target is a clean error and posts NO approval card" do
      operator_id = "cp-op-#{System.unique_integer([:positive])}"
      target = "no-such-workspace-#{System.unique_integer([:positive])}"

      assert {:error, msg} =
               DeleteWorkspace.execute(%{agent_id: operator_id, target: target}, %{})

      assert msg =~ "Couldn't resolve workspace"
      assert pending_for(operator_id) == []
    end

    test "posts a blocking approval card and does NOT delete synchronously; deny keeps the workspace" do
      operator_id = "cp-op-#{System.unique_integer([:positive])}"
      project_id = register_project("cp-ws-proj-#{System.unique_integer([:positive])}")
      ws_id = register_workspace(project_id, "cp-doomed-ws-#{System.unique_integer([:positive])}")

      task =
        Task.async(fn ->
          DeleteWorkspace.execute(%{agent_id: operator_id, target: ws_id}, %{})
        end)

      id = wait_for_pending(operator_id)

      assert [{^id, _entry}] = pending_for(operator_id)
      assert %{id: ^ws_id} = Loopyard.WorkspaceRegistry.get_workspace(ws_id)

      assert :ok = Approvals.decide(id, :deny)
      assert {:ok, msg} = Task.await(task, 1_500)
      assert msg =~ "declined"

      assert %{id: ^ws_id} = Loopyard.WorkspaceRegistry.get_workspace(ws_id)
      assert pending_for(operator_id) == []
    end
  end

  # --- helpers ---

  # Fabricated registry rows — pure ETS, no source adapter, no Docker.
  defp register_project(name) do
    id = "cp-proj-#{System.unique_integer([:positive])}"
    Loopyard.ProjectRegistry.register(%{id: id, name: name, path: "/tmp/fake-#{id}"})
    on_exit(fn -> :ets.delete(:project_registry, id) end)
    id
  end

  defp register_workspace(project_id, name) do
    id = "cp-ws-#{System.unique_integer([:positive])}"

    Loopyard.WorkspaceRegistry.insert(id, %{
      id: id,
      project_id: project_id,
      name: name,
      branch: name,
      path: "/tmp/fake-#{id}",
      is_main: false,
      status: :stopped
    })

    on_exit(fn -> Loopyard.WorkspaceRegistry.delete(id) end)
    id
  end

  # A fabricated agent summary row — what every fleet read (overview,
  # resolve_agent) consumes. No GenServer: casts to it are no-ops.
  defp fake_agent(ws_id, name, status) do
    id = "cp-agent-#{System.unique_integer([:positive])}"

    :ets.insert(:chat_agents, {
      id,
      %{
        id: id,
        name: name,
        status: status,
        workspace_id: ws_id,
        harness: :claude,
        model: "claude-opus-5",
        workstation_identity: "brad",
        messages: [],
        errors: 0
      }
    })

    on_exit(fn -> :ets.delete(:chat_agents, id) end)
    id
  end

  # Only THIS operator's blocking approvals — other tests may have entries.
  defp pending_for(operator_id) do
    Approvals.pending_all()
    |> Enum.filter(fn {_id, entry} -> entry.agent_id == operator_id end)
  end

  defp wait_for_pending(operator_id, tries \\ 50) do
    case pending_for(operator_id) do
      [{id, _entry} | _] ->
        id

      [] when tries > 0 ->
        Process.sleep(10)
        wait_for_pending(operator_id, tries - 1)
    end
  end
end
