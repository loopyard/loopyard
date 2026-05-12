defmodule Loopyard.WorkspaceGroupTest do
  use ExUnit.Case

  alias Loopyard.{WorkspaceGroup, WorkspaceSupervisor}

  setup do
    Loopyard.StateKeeper.ensure_tables!()
    :ok
  end

  describe "start/stop lifecycle" do
    test "start_workspace starts a workspace supervisor subtree" do
      path = File.cwd!()
      workspace_id = Loopyard.Workspace.workspace_id(path)

      assert {:ok, _} = WorkspaceSupervisor.start_workspace(workspace_id, path)
      assert WorkspaceGroup.whereis(workspace_id) != nil
      assert WorkspaceSupervisor.workspace_running?(workspace_id)

      # Clean up
      WorkspaceSupervisor.stop_workspace(workspace_id)
    end

    test "stop_workspace stops the subtree" do
      path = File.cwd!()
      workspace_id = Loopyard.Workspace.workspace_id(path)

      {:ok, _} = WorkspaceSupervisor.start_workspace(workspace_id, path)
      assert WorkspaceSupervisor.workspace_running?(workspace_id)

      assert :ok = WorkspaceSupervisor.stop_workspace(workspace_id)
      # Registry deregistration is async after terminate
      Process.sleep(50)
      refute WorkspaceSupervisor.workspace_running?(workspace_id)
    end

    test "starting an already-running workspace is idempotent" do
      path = File.cwd!()
      workspace_id = Loopyard.Workspace.workspace_id(path)

      {:ok, _} = WorkspaceSupervisor.start_workspace(workspace_id, path)
      # Second call returns :ok regardless of whether it hit the
      # :already_running short-circuit (healthy) or the auto-recovery
      # rebuild (ServiceManager died between calls). Both are "you're
      # good" outcomes for the caller.
      assert {:ok, _} = WorkspaceSupervisor.start_workspace(workspace_id, path)

      WorkspaceSupervisor.stop_workspace(workspace_id)
    end

    test "agents can be started under a workspace" do
      path = File.cwd!()
      workspace_id = Loopyard.Workspace.workspace_id(path)

      {:ok, _} = WorkspaceSupervisor.start_workspace(workspace_id, path)

      agent_id = "workspace-test-#{:rand.uniform(100_000)}"

      assert {:ok, _pid} =
               WorkspaceGroup.start_agent(workspace_id,
                 id: agent_id,
                 name: "Test Agent",
                 working_dir: path,
                 started_by: "test"
               )

      # Agent should be running
      state = Loopyard.ChatAgent.get_state(agent_id)
      assert state != nil
      assert state.name == "Test Agent"

      # Stopping the workspace should kill the agent
      WorkspaceSupervisor.stop_workspace(workspace_id)
      Process.sleep(100)

      # Agent should be gone (GenServer stopped)
      # ETS still has it
      assert Loopyard.ChatAgent.get_state(agent_id) != nil
      # But the process should be dead
      refute match?([{_, _}], Registry.lookup(Loopyard.ChatAgentRegistry, agent_id))
    end

    test "start_agent returns error when workspace not running" do
      assert {:error, :workspace_not_running} =
               WorkspaceGroup.start_agent("nonexistent", id: "x", name: "x")
    end
  end
end
