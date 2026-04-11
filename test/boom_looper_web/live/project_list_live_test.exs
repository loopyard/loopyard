defmodule BoomLooperWeb.ProjectListLiveTest do
  use BoomLooperWeb.ConnCase

  import Phoenix.LiveViewTest

  setup do
    BoomLooper.StateKeeper.ensure_tables!()
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

    test "mount returns under 500ms — pure ETS reads, no shell-outs", %{conn: conn} do
      {micros, {:ok, _view, _html}} = :timer.tc(fn -> live(conn, "/") end)
      assert micros < 500_000,
        "ProjectListLive mount took #{div(micros, 1000)}ms — slow call slipped in"
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
