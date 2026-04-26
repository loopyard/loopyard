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
    @tag timeout: 30_000
    test "confirming removes project and redirects home", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, "/projects/#{project.id}")
      view |> element("button", "Remove project") |> render_click()

      # `remove_project` now uses start_async, so render_click returns
      # the intermediate "Removing…" state. The actual redirect lands
      # later via handle_async; use assert_redirect to wait for it.
      view |> element("button", "Remove project") |> render_click()
      assert_redirect(view, "/", 25_000)

      assert ProjectRegistry.get_project(project.id) == nil
      assert ProjectRegistry.list_workspaces(project.id) == []
    end

    @tag timeout: 10_000
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

      # remove_project starts an async Task (start_async) — wait until
      # ProjectRegistry confirms the project is gone before asserting
      # that the .boomlooper dir was deleted. Cleanup walks child dirs
      # + calls Docker; under full-suite I/O contention this routinely
      # takes 3–5 seconds. Keep the wait below the @tag timeout (10s).
      wait_until(fn -> ProjectRegistry.get_project(project.id) == nil end, 8_000)

      refute File.dir?(boomlooper_dir)
      assert File.dir?(tmp_dir)
      File.rm_rf!(tmp_dir)
    end
  end

  defp wait_until(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    wait_until_loop(fun, deadline)
  end

  defp wait_until_loop(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("wait_until timed out")
      else
        Process.sleep(25)
        wait_until_loop(fun, deadline)
      end
    end
  end
end
