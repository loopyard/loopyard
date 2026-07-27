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
