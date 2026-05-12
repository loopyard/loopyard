defmodule Loopyard.ContainerMonitorTest do
  use ExUnit.Case
  # One test sleeps 6s waiting for the poll loop. Excluded from the
  # default run; opt in with `mix test --include slow`.
  @moduletag :slow

  alias Loopyard.ContainerMonitor

  test "starts and polls without crashing" do
    # Start a monitor for a non-existent path — should not crash
    {:ok, pid} =
      ContainerMonitor.start_link(project_dir: "/nonexistent/#{:rand.uniform(100_000)}")

    assert Process.alive?(pid)

    # Let it poll at least once
    Process.sleep(100)
    assert Process.alive?(pid)

    GenServer.stop(pid)
  end

  test "polls without crashing when ServiceManager exists" do
    path = File.cwd!()
    workspace_id = Loopyard.Workspace.workspace_id(path)

    Loopyard.WorkspaceSupervisor.start_workspace(workspace_id, path)

    {:ok, pid} = ContainerMonitor.start_link(project_dir: path)

    # Let it poll at least once
    Process.sleep(6_000)
    assert Process.alive?(pid)

    GenServer.stop(pid)
    Loopyard.WorkspaceSupervisor.stop_workspace(workspace_id)
    Process.sleep(50)
  end
end
