defmodule BoomLooperWeb.ProjectListLiveTest do
  use BoomLooperWeb.ConnCase

  import Phoenix.LiveViewTest

  setup do
    BoomLooper.ProjectRegistry.ensure_ets_tables()
    # Clean up projects from other tests
    BoomLooper.ProjectRegistry.list_projects() |> Enum.each(&BoomLooper.ProjectRegistry.remove_project(&1.id))
    :ok
  end

  describe "mount" do
    test "renders the project list page at /", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      assert html =~ "Projects"
      assert html =~ "Launch Command"
    end
  end

  describe "empty state" do
    test "shows empty state when no projects", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      assert html =~ "No projects yet"
    end
  end

  describe "add project" do
    test "adding invalid path shows error", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view
      |> element("form[phx-submit='add_project']")
      |> render_submit(%{"path" => "/no/such/path/xyz"})

      html = render(view)
      assert html =~ "does not exist"
    end
  end
end
