defmodule HiveWeb.ChatLiveTest do
  use HiveWeb.ConnCase

  import Phoenix.LiveViewTest

  describe "mount" do
    test "renders the chat page", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Hive"
      assert html =~ "New Agent"
      assert html =~ "No agents yet"
      assert html =~ "Terminal mode"
    end

    test "shows agent count", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      assert html =~ "0 agents"
    end
  end

  describe "new agent form" do
    test "toggles form visibility", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      refute has_element?(view, "form[phx-submit='spawn_agent']")

      view |> element("button", "New Agent") |> render_click()
      assert has_element?(view, "form[phx-submit='spawn_agent']")
    end

    test "cancel hides the form", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view |> element("button", "New Agent") |> render_click()
      assert has_element?(view, "form[phx-submit='spawn_agent']")

      view |> element("button", "Cancel") |> render_click()
      refute has_element?(view, "form[phx-submit='spawn_agent']")
    end
  end

  describe "empty state" do
    test "shows prompt to create agent", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      assert html =~ "Create or select an agent"
    end
  end
end
