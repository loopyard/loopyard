defmodule HiveWeb.ChatLiveTest do
  use HiveWeb.ConnCase

  import Phoenix.LiveViewTest

  describe "mount" do
    test "renders the chat page at /", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Boom Looper"
      assert html =~ "New Agent"
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

    test "spawning an agent auto-selects it", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view |> element("button", "New Agent") |> render_click()

      view
      |> element("form[phx-submit='spawn_agent']")
      |> render_submit(%{"name" => "Test Agent", "working_dir" => File.cwd!()})

      # Should redirect to /chat/:id
      assert_patch(view)
    end
  end

  describe "empty state" do
    test "shows prompt to create or select agent", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      assert html =~ "Create or select an agent"
    end
  end

  describe "handle_params with /chat/:id" do
    test "unknown id redirects to /", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, "/chat/nonexistent123")
    end
  end

  describe "tabs" do
    test "defaults to chat tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Spawn an agent
      view |> element("button", "New Agent") |> render_click()
      view |> element("form[phx-submit='spawn_agent']") |> render_submit(%{"name" => "Tab Test", "working_dir" => File.cwd!()})
      assert_patch(view)

      # Chat tab should be active by default
      html = render(view)
      assert html =~ "Chat"
      assert html =~ "Ops"
    end

    test "switch to ops tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Spawn an agent
      view |> element("button", "New Agent") |> render_click()
      view |> element("form[phx-submit='spawn_agent']") |> render_submit(%{"name" => "Ops Tab Test", "working_dir" => File.cwd!()})
      assert_patch(view)

      # Switch to ops tab
      view |> element("button[phx-click='switch_tab'][phx-value-tab='ops']") |> render_click()
      assert_patch(view)

      html = render(view)
      assert html =~ "Tools"
      assert html =~ "Errors"
      assert html =~ "Messages"
    end
  end
end
