defmodule HiveWeb.DashboardLiveTest do
  use HiveWeb.ConnCase

  import Phoenix.LiveViewTest

  @terminal_path "/terminal"

  describe "terminal mode" do
    test "renders the dashboard", %{conn: conn} do
      {:ok, _view, html} = live(conn, @terminal_path)

      assert html =~ "Hive"
      assert html =~ "New Agent"
      assert html =~ "Templates"
    end

    test "toggles new agent form", %{conn: conn} do
      {:ok, view, _html} = live(conn, @terminal_path)

      view |> element("button", "New Agent") |> render_click()
      assert has_element?(view, "form[phx-submit='spawn_agent']")

      view |> element("button", "Cancel") |> render_click()
      refute has_element?(view, "form[phx-submit='spawn_agent']")
    end
  end
end
