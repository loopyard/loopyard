defmodule BoomLooper.WorkspaceSupervisorTest do
  use ExUnit.Case, async: false

  alias BoomLooper.WorkspaceSupervisor

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "boom-looper-ws-sup-test-#{:rand.uniform(100_000)}")
    File.mkdir_p!(tmp_dir)
    workspace_id = BoomLooper.Workspace.workspace_id(tmp_dir)

    on_exit(fn ->
      WorkspaceSupervisor.stop_workspace(workspace_id)
      File.rm_rf!(tmp_dir)
    end)

    %{tmp_dir: tmp_dir, workspace_id: workspace_id}
  end

  describe "start_workspace/2" do
    test "starts a workspace subtree", %{workspace_id: ws_id, tmp_dir: tmp_dir} do
      assert {:ok, _pid} = WorkspaceSupervisor.start_workspace(ws_id, tmp_dir)
      assert WorkspaceSupervisor.workspace_running?(ws_id)
    end

    test "returns :already_running for duplicate start", %{workspace_id: ws_id, tmp_dir: tmp_dir} do
      {:ok, _} = WorkspaceSupervisor.start_workspace(ws_id, tmp_dir)
      assert {:ok, :already_running} = WorkspaceSupervisor.start_workspace(ws_id, tmp_dir)
    end
  end

  describe "stop_workspace/1" do
    test "stops a running workspace", %{workspace_id: ws_id, tmp_dir: tmp_dir} do
      {:ok, _} = WorkspaceSupervisor.start_workspace(ws_id, tmp_dir)
      assert :ok = WorkspaceSupervisor.stop_workspace(ws_id)
      # Registry cleanup is async — give it a moment
      Process.sleep(50)
      refute WorkspaceSupervisor.workspace_running?(ws_id)
    end

    test "returns error for non-existent workspace" do
      assert {:error, :not_found} = WorkspaceSupervisor.stop_workspace("nonexistent-#{:rand.uniform(100_000)}")
    end
  end

  describe "workspace_running?/1" do
    test "returns false for unknown workspace" do
      refute WorkspaceSupervisor.workspace_running?("nonexistent-#{:rand.uniform(100_000)}")
    end
  end
end
