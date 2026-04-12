defmodule BoomLooperWeb.ProjectLiveTest do
  use BoomLooperWeb.ConnCase

  import Phoenix.LiveViewTest

  alias BoomLooper.ProjectRegistry

  setup do
    BoomLooper.StateKeeper.ensure_tables!()
    # Wipe ETS directly — much faster than calling remove_project which
    # does synchronous Docker cleanup and can timeout in tests.
    :ets.delete_all_objects(:project_registry)
    :ets.delete_all_objects(:workspace_registry)

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

    test "mount returns under 500ms — service/volume counts load async", %{conn: conn, project: project} do
      {micros, {:ok, _view, _html}} = :timer.tc(fn -> live(conn, "/projects/#{project.id}") end)
      assert micros < 500_000,
        "ProjectLive mount took #{div(micros, 1000)}ms — sync slow call slipped in"
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

  describe "remove project" do
    test "shows confirmation screen before removing", %{conn: conn, project: project} do
      {:ok, view, html} = live(conn, "/projects/#{project.id}")
      assert html =~ "Remove project"

      # Click Remove project — shows confirmation, doesn't delete yet
      html = view |> element("button", "Remove project") |> render_click()
      assert html =~ "Directory to delete"
      assert html =~ "Docker containers to stop"
      assert ProjectRegistry.get_project(project.id) != nil
    end

    @tag timeout: 5_000
    test "cancel returns to project view", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, "/projects/#{project.id}")
      view |> element("button", "Remove project") |> render_click()

      html = view |> element("button", "Cancel") |> render_click()
      refute html =~ "Directory to delete"
      assert html =~ project.name
      assert ProjectRegistry.get_project(project.id) != nil
    end

    @tag :docker
    test "confirming removes project and redirects home", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, "/projects/#{project.id}")
      view |> element("button", "Remove project") |> render_click()

      assert {:error, {:live_redirect, %{to: "/"}}} =
               view |> element("button", "Remove project") |> render_click()

      assert ProjectRegistry.get_project(project.id) == nil
      assert ProjectRegistry.list_workspaces(project.id) == []
    end

    test "deletes .boomlooper directory" do
      tmp_dir = Path.join(System.tmp_dir!(), "bl-remove-test-#{:rand.uniform(100_000)}")
      File.mkdir_p!(tmp_dir)
      boomlooper_dir = Path.join(tmp_dir, ".boomlooper")
      File.mkdir_p!(Path.join(boomlooper_dir, "workspace"))
      File.mkdir_p!(Path.join(boomlooper_dir, "repo"))
      File.write!(Path.join(boomlooper_dir, "workspace/docker-compose.yml"), "{}")
      File.write!(Path.join(boomlooper_dir, "repo/workspace.json"), "{}")

      {:ok, project, _} = ProjectRegistry.add(tmp_dir)

      conn = build_conn()
      {:ok, view, _html} = live(conn, "/projects/#{project.id}")
      view |> element("button", "Remove project") |> render_click()
      view |> element("button", "Remove project") |> render_click()

      refute File.dir?(boomlooper_dir)
      assert File.dir?(tmp_dir)
      File.rm_rf!(tmp_dir)
    end
  end
end
