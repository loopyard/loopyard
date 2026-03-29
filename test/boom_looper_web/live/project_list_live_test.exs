defmodule BoomLooperWeb.ProjectListLiveTest do
  use BoomLooperWeb.ConnCase

  import Phoenix.LiveViewTest

  setup do
    BoomLooper.ProjectRegistry.ensure_ets_tables()
    BoomLooper.ProjectRegistry.list_projects() |> Enum.each(&BoomLooper.ProjectRegistry.remove_project(&1.id))
    :ok
  end

  describe "mount" do
    test "renders the home page with project input and launch command", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      assert html =~ "Boom Looper"
      assert html =~ "From terminal"
      assert html =~ "Paste a path"
    end

    test "shows Remote and System links in header", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      assert html =~ "Remote"
      assert html =~ "System"
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
