defmodule BoomLooper.WorkspaceRegistryTest do
  use ExUnit.Case, async: false

  alias BoomLooper.WorkspaceRegistry

  setup do
    # Clean workspace table between tests
    :ets.delete_all_objects(:workspace_registry)
    :ok
  end

  describe "get_workspace/1" do
    test "returns nil for unknown id" do
      assert WorkspaceRegistry.get_workspace("nonexistent") == nil
    end

    test "returns workspace after insert" do
      ws = %{id: "ws-1", project_id: "proj-1", name: "main", path: "/tmp/test", is_main: true, status: :stopped}
      WorkspaceRegistry.insert("ws-1", ws)
      result = WorkspaceRegistry.get_workspace("ws-1")
      assert result.id == "ws-1"
      assert result.name == "main"
    end

    test "normalizes workspace — adds is_main if missing" do
      ws = %{id: "ws-2", project_id: "proj-1", name: "dev", path: "/tmp/dev"}
      WorkspaceRegistry.insert("ws-2", ws)
      result = WorkspaceRegistry.get_workspace("ws-2")
      assert result.is_main == false
    end
  end

  describe "list_workspaces/1" do
    test "returns empty list when no workspaces" do
      assert WorkspaceRegistry.list_workspaces("proj-1") == []
    end

    test "filters by project_id" do
      WorkspaceRegistry.insert("ws-a", %{id: "ws-a", project_id: "proj-1", name: "main", path: "/a", is_main: true})
      WorkspaceRegistry.insert("ws-b", %{id: "ws-b", project_id: "proj-2", name: "main", path: "/b", is_main: true})

      result = WorkspaceRegistry.list_workspaces("proj-1")
      assert length(result) == 1
      assert hd(result).id == "ws-a"
    end

    test "main workspace sorts first" do
      WorkspaceRegistry.insert("ws-dev", %{id: "ws-dev", project_id: "p1", name: "dev", path: "/dev", is_main: false})
      WorkspaceRegistry.insert("ws-main", %{id: "ws-main", project_id: "p1", name: "main", path: "/main", is_main: true})

      result = WorkspaceRegistry.list_workspaces("p1")
      assert hd(result).name == "main"
    end
  end

  describe "update_workspace_status/2" do
    test "updates status" do
      WorkspaceRegistry.insert("ws-1", %{id: "ws-1", project_id: "p1", name: "main", path: "/tmp", is_main: true, status: :stopped})
      assert {:ok, updated} = WorkspaceRegistry.update_workspace_status("ws-1", :running)
      assert updated.status == :running

      fetched = WorkspaceRegistry.get_workspace("ws-1")
      assert fetched.status == :running
    end

    test "returns error for unknown workspace" do
      assert {:error, _} = WorkspaceRegistry.update_workspace_status("nope", :running)
    end
  end

  describe "delete/1" do
    test "removes workspace" do
      WorkspaceRegistry.insert("ws-1", %{id: "ws-1", project_id: "p1", name: "main", path: "/tmp", is_main: true})
      assert WorkspaceRegistry.get_workspace("ws-1") != nil
      WorkspaceRegistry.delete("ws-1")
      assert WorkspaceRegistry.get_workspace("ws-1") == nil
    end
  end

  describe "worktree_path normalization" do
    test "backfills worktree_path from path for host-dir workspaces" do
      # Simulate a pre-refactor workspace: has path but no worktree_path
      WorkspaceRegistry.insert("ws-local", %{
        id: "ws-local", project_id: "p1", name: "main",
        path: "/tmp/myproject", is_main: true, status: :stopped
      })

      ws = WorkspaceRegistry.get_workspace("ws-local")
      assert ws.worktree_path == "/tmp/myproject",
        "worktree_path should be backfilled from path for host-dir workspaces"
    end

    test "does NOT backfill for virtual workspace dirs" do
      virtual_path = Path.join([BoomLooper.Workspace.home_dir(), "workspaces", "ws-virt"])

      WorkspaceRegistry.insert("ws-virt", %{
        id: "ws-virt", project_id: "p1", name: "main",
        path: virtual_path, is_main: true, status: :stopped
      })

      ws = WorkspaceRegistry.get_workspace("ws-virt")
      refute ws[:worktree_path],
        "worktree_path should NOT be set for virtual workspace dirs"
    end

    test "preserves explicit worktree_path" do
      WorkspaceRegistry.insert("ws-explicit", %{
        id: "ws-explicit", project_id: "p1", name: "feature",
        path: "/tmp/myproject",
        worktree_path: "/tmp/custom-worktree",
        is_main: false, status: :stopped
      })

      ws = WorkspaceRegistry.get_workspace("ws-explicit")
      assert ws.worktree_path == "/tmp/custom-worktree",
        "explicit worktree_path should not be overwritten"
    end

    test "find_or_create_workspace sets worktree_path for host paths" do
      :ets.insert(:project_registry, {"p-local", %{
        id: "p-local", name: "test", path: "/tmp/anotherproject",
        source_type: :local, is_git: true
      }})

      ws = WorkspaceRegistry.find_or_create_workspace("p-local", "main", "/tmp/anotherproject")
      assert ws.worktree_path == "/tmp/anotherproject"
    end
  end

  describe "workspace_id/1" do
    test "generates deterministic ID from path" do
      id1 = WorkspaceRegistry.workspace_id("/tmp/my-project")
      id2 = WorkspaceRegistry.workspace_id("/tmp/my-project")
      assert id1 == id2
      assert is_binary(id1)
    end

    test "different paths produce different IDs" do
      id1 = WorkspaceRegistry.workspace_id("/tmp/project-a")
      id2 = WorkspaceRegistry.workspace_id("/tmp/project-b")
      assert id1 != id2
    end
  end
end
