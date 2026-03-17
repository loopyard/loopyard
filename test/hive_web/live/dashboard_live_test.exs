defmodule HiveWeb.DashboardLiveTest do
  use HiveWeb.ConnCase

  import Phoenix.LiveViewTest

  describe "mount" do
    test "renders the dashboard", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Hive"
      assert html =~ "New Agent"
      assert html =~ "Templates"
      assert html =~ "No agents yet"
    end

    test "shows agent count", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      assert html =~ "0 agents"
    end
  end

  describe "new agent form" do
    test "toggles new agent form visibility", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Form should be hidden initially
      refute has_element?(view, "form[phx-submit='spawn_agent']")

      # Click to show form
      html = view |> element("button", "New Agent") |> render_click()
      assert html =~ "Working Directory"
      assert html =~ "Launch"
    end

    test "cancel hides the form", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Show form
      view |> element("button", "New Agent") |> render_click()
      assert has_element?(view, "form[phx-submit='spawn_agent']")

      # Cancel
      view |> element("button", "Cancel") |> render_click()
      refute has_element?(view, "form[phx-submit='spawn_agent']")
    end

    test "rejects invalid working directory without crashing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Show form
      view |> element("button", "New Agent") |> render_click()

      # Submit with invalid directory — should not crash, form stays open
      view
      |> element("form[phx-submit='spawn_agent']")
      |> render_submit(%{"name" => "Test", "working_dir" => "/nonexistent/path/xyz"})

      # The view should still be alive (didn't crash) and form still visible
      assert has_element?(view, "form[phx-submit='spawn_agent']")
      assert render(view) =~ "Launch"
    end
  end

  describe "template picker" do
    test "toggles template picker visibility", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Templates hidden initially
      refute has_element?(view, "button[phx-click='use_template']")

      # Show templates
      view |> element("button", "Templates") |> render_click()

      # Should show template options
      assert has_element?(view, "button[phx-click='use_template']")
    end

    test "using a template populates the form", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Show templates
      view |> element("button", "Templates") |> render_click()

      # Click first template
      html =
        view
        |> element("button[phx-click='use_template'][phx-value-index='0']")
        |> render_click()

      # Should switch to form with template name
      assert html =~ "General Assistant"
      assert has_element?(view, "form[phx-submit='spawn_agent']")
    end
  end

  describe "empty state" do
    test "shows empty state when no agent selected", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      assert html =~ "Select an agent to view its terminal"
    end
  end
end
