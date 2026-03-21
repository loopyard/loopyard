defmodule BoomLooperWeb.ProjectLiveTest do
  use BoomLooperWeb.ConnCase

  import Phoenix.LiveViewTest

  alias BoomLooper.ProjectRegistry

  setup do
    ProjectRegistry.ensure_ets_tables()
    ProjectRegistry.list_projects() |> Enum.each(&ProjectRegistry.remove_project(&1.id))

    path = File.cwd!()
    {:ok, project, workspace} = ProjectRegistry.add(path)

    %{project: project, workspace: workspace}
  end

  describe "mount" do
    test "renders project page with workspaces", %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, "/projects/#{project.id}")
      assert html =~ project.name
      assert html =~ "main"
    end

    test "redirects to / for unknown project", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, "/projects/nonexistent")
    end
  end

  describe "workspace list" do
    test "shows the main workspace", %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, "/projects/#{project.id}")
      workspaces = ProjectRegistry.list_workspaces(project.id)
      assert length(workspaces) >= 1
      assert html =~ "default"
    end
  end
end
