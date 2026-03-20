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

  test "broadcasts when ServiceManager exists" do
    path = File.cwd!()
    branch_id = BoomLooper.Workspace.workspace_id(path)

    # Start a branch so ServiceManager exists
    BoomLooper.BranchSupervisor.start_branch(branch_id, path)

    # Subscribe to service updates
    Phoenix.PubSub.subscribe(BoomLooper.PubSub, "workspace_services")

    # Start monitor — it should broadcast within 5 seconds
    {:ok, pid} = ContainerMonitor.start_link(project_dir: path)

    # Wait for a broadcast
    assert_receive {:services_updated, ^path, _statuses}, 10_000

    GenServer.stop(pid)
    BoomLooper.BranchSupervisor.stop_branch(branch_id)
    Process.sleep(50)
  end
end
