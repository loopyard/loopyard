defmodule BoomLooperWeb.ProjectLiveTest do
  use BoomLooperWeb.ConnCase

  import Phoenix.LiveViewTest

  alias BoomLooper.ProjectRegistry

  setup do
    ProjectRegistry.ensure_ets_tables()
    ProjectRegistry.list_projects() |> Enum.each(&ProjectRegistry.remove_project(&1.id))

    path = File.cwd!()
    {:ok, project, branch} = ProjectRegistry.add(path)

    %{project: project, branch: branch}
  end

  describe "mount" do
    test "renders project page with branches", %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, "/p/#{project.id}")
      assert html =~ project.name
      assert html =~ "main"
    end

    test "redirects to / for unknown project", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, "/p/nonexistent")
    end
  end

  describe "branch list" do
    test "shows the main branch", %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, "/p/#{project.id}")
      branches = ProjectRegistry.list_branches(project.id)
      assert length(branches) >= 1
      assert html =~ "default"
    end
  end
end
