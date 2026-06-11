defmodule Loopyard.Events.WorkspacesTest do
  use ExUnit.Case, async: false

  alias Loopyard.Events.Workspaces
  alias Loopyard.WorkspaceRegistry

  setup do
    Loopyard.StateKeeper.ensure_tables!()
    :ok
  end

  test "WorkspaceRegistry.insert broadcasts :created to the project's topic" do
    pid = "proj-#{System.unique_integer([:positive])}"
    ws_id = "ws-#{System.unique_integer([:positive])}"
    Workspaces.subscribe(pid)

    WorkspaceRegistry.insert(ws_id, %{id: ws_id, project_id: pid, status: :stopped})

    assert_receive %Workspaces.Changed{project_id: ^pid, action: :created, workspace_id: ^ws_id}
  end

  test "update_workspace_status broadcasts :status" do
    pid = "proj-#{System.unique_integer([:positive])}"
    ws_id = "ws-#{System.unique_integer([:positive])}"
    WorkspaceRegistry.insert(ws_id, %{id: ws_id, project_id: pid, status: :stopped})
    Workspaces.subscribe(pid)

    {:ok, _} = WorkspaceRegistry.update_workspace_status(ws_id, :running)

    assert_receive %Workspaces.Changed{project_id: ^pid, action: :status, workspace_id: ^ws_id}
  end

  test "delete broadcasts :removed with the project's id (looked up before deletion)" do
    pid = "proj-#{System.unique_integer([:positive])}"
    ws_id = "ws-#{System.unique_integer([:positive])}"
    WorkspaceRegistry.insert(ws_id, %{id: ws_id, project_id: pid, status: :stopped})
    Workspaces.subscribe(pid)

    WorkspaceRegistry.delete(ws_id)

    assert_receive %Workspaces.Changed{project_id: ^pid, action: :removed, workspace_id: ^ws_id}
  end

  test "a workspace with no project_id does not crash or broadcast" do
    ws_id = "ws-#{System.unique_integer([:positive])}"
    # No subscription, no project_id — insert must still succeed silently.
    assert WorkspaceRegistry.insert(ws_id, %{id: ws_id, status: :stopped})
  end
end
