defmodule LoopyardWeb.ProjectListLiveTest do
  use LoopyardWeb.ConnCase

  import Phoenix.LiveViewTest

  setup do
    Loopyard.StateKeeper.ensure_tables!()
    :ets.delete_all_objects(:project_registry)
    :ets.delete_all_objects(:workspace_registry)
    :ok
  end

  describe "mount" do
    # The home page is now a projects list + a "New project" button; the
    # creation methods (folder/scratch/github) each live on their own screen.
    test "renders the workspaces page with the grouped list and New project", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/workspaces")
      assert html =~ "Loopyard"
      assert html =~ "Workspaces"
      assert html =~ "New project"
    end

    test "home dashboard surfaces Remote and System", %{conn: conn} do
      # The Remote/System chrome moved off the workspaces list onto the home
      # dashboard (commit 6450c3d dropped the top nav; they're cards on "/" now).
      {:ok, _view, html} = live(conn, "/")
      assert html =~ "Remote"
      assert html =~ "System"
    end

    test "mount returns under 500ms — pure ETS reads, no shell-outs", %{conn: conn} do
      {micros, {:ok, _view, _html}} = :timer.tc(fn -> live(conn, "/workspaces") end)

      assert micros < 500_000,
             "ProjectListLive mount took #{div(micros, 1000)}ms — slow call slipped in"
    end
  end

  describe "new project from a folder" do
    test "the folder screen has the path form + the terminal launch command", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/projects/new/folder")
      assert html =~ "form"
      assert html =~ "terminal"
      assert html =~ "add_project"
    end

    test "adding an invalid path shows an error", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/projects/new/folder")

      view
      |> element("form[phx-submit='add_project']")
      |> render_submit(%{"path" => "/no/such/path/xyz"})

      html = render(view)
      assert html =~ "does not exist"
    end
  end
end
