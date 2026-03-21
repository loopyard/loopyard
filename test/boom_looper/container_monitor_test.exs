defmodule BoomLooper.ContainerMonitorTest do
  use ExUnit.Case

  alias BoomLooper.ContainerMonitor

  test "starts and polls without crashing" do
    # Start a monitor for a non-existent path — should not crash
    {:ok, pid} = ContainerMonitor.start_link(project_dir: "/nonexistent/#{:rand.uniform(100_000)}")
    assert Process.alive?(pid)

    # Let it poll at least once
    Process.sleep(100)
    assert Process.alive?(pid)

    GenServer.stop(pid)
  end

  test "polls without crashing when ServiceManager exists" do
    path = File.cwd!()
    branch_id = BoomLooper.Workspace.workspace_id(path)

    BoomLooper.BranchSupervisor.start_branch(branch_id, path)

    {:ok, pid} = ContainerMonitor.start_link(project_dir: path)

    # Let it poll at least once
    Process.sleep(6_000)
    assert Process.alive?(pid)

    GenServer.stop(pid)
    BoomLooper.BranchSupervisor.stop_branch(branch_id)
    Process.sleep(50)
  end
end
