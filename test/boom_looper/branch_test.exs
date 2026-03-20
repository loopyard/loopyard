defmodule BoomLooper.BranchTest do
  use ExUnit.Case

  alias BoomLooper.{Branch, BranchSupervisor, ProjectRegistry}

  setup do
    ProjectRegistry.ensure_ets_tables()
    :ok
  end

  describe "start/stop lifecycle" do
    test "start_branch starts a branch supervisor subtree" do
      path = File.cwd!()
      branch_id = BoomLooper.Workspace.workspace_id(path)

      assert {:ok, _} = BranchSupervisor.start_branch(branch_id, path)
      assert Branch.whereis(branch_id) != nil
      assert BranchSupervisor.branch_running?(branch_id)

      # Clean up
      BranchSupervisor.stop_branch(branch_id)
    end

    test "stop_branch stops the subtree" do
      path = File.cwd!()
      branch_id = BoomLooper.Workspace.workspace_id(path)

      {:ok, _} = BranchSupervisor.start_branch(branch_id, path)
      assert BranchSupervisor.branch_running?(branch_id)

      assert :ok = BranchSupervisor.stop_branch(branch_id)
      # Registry deregistration is async after terminate
      Process.sleep(50)
      refute BranchSupervisor.branch_running?(branch_id)
    end

    test "starting an already-running branch returns :already_running" do
      path = File.cwd!()
      branch_id = BoomLooper.Workspace.workspace_id(path)

      {:ok, _} = BranchSupervisor.start_branch(branch_id, path)
      assert {:ok, :already_running} = BranchSupervisor.start_branch(branch_id, path)

      BranchSupervisor.stop_branch(branch_id)
    end

    test "agents can be started under a branch" do
      path = File.cwd!()
      branch_id = BoomLooper.Workspace.workspace_id(path)

      {:ok, _} = BranchSupervisor.start_branch(branch_id, path)

      agent_id = "branch-test-#{:rand.uniform(100_000)}"
      assert {:ok, _pid} = Branch.start_agent(branch_id,
        id: agent_id,
        name: "Test Agent",
        working_dir: path,
        started_by: "test"
      )

      # Agent should be running
      state = BoomLooper.ChatAgent.get_state(agent_id)
      assert state != nil
      assert state.name == "Test Agent"

      # Stopping the branch should kill the agent
      BranchSupervisor.stop_branch(branch_id)
      Process.sleep(100)

      # Agent should be gone (GenServer stopped)
      assert BoomLooper.ChatAgent.get_state(agent_id) != nil  # ETS still has it
      # But the process should be dead
      refute match?([{_, _}], Registry.lookup(BoomLooper.ChatAgentRegistry, agent_id))
    end

    test "start_agent returns error when branch not running" do
      assert {:error, :branch_not_running} = Branch.start_agent("nonexistent", id: "x", name: "x")
    end
  end
end
