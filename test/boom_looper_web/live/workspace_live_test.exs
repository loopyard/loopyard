defmodule BoomLooperWeb.WorkspaceLiveTest do
  use BoomLooperWeb.ConnCase

  import Phoenix.LiveViewTest

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "boom-looper-ws-live-test-#{:rand.uniform(100_000)}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    %{tmp_dir: tmp_dir}
  end

  describe "mount" do
    test "renders the workspace list page at /", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      assert html =~ "Workspaces"
      assert html =~ "Add"
    end
  end

  describe "add workspace" do
    test "adding a valid path creates workspace and redirects to workspace view", %{conn: conn, tmp_dir: tmp_dir} do
      {:ok, view, _html} = live(conn, "/")

      view
      |> element("form[phx-submit='add_workspace']")
      |> render_submit(%{"path" => tmp_dir})

      {path, _flash} = assert_redirect(view)
      assert path =~ "/w/"

      # Follow redirect — should render the ChatLive workspace page
      {:ok, _view, html} = live(conn, path)
      assert html =~ "New Agent"
    end

    test "adding invalid path shows error message", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view
      |> element("form[phx-submit='add_workspace']")
      |> render_submit(%{"path" => "/no/such/path/xyz"})

      # Should stay on the same page and show the error
      html = render(view)
      assert html =~ "Workspaces"
      assert html =~ "does not exist"
    end
  end

  describe "workspace list" do
    test "shows added workspaces", %{conn: conn, tmp_dir: tmp_dir} do
      {:ok, _ws} = BoomLooper.WorkspaceRegistry.add(tmp_dir)

      {:ok, _view, html} = live(conn, "/")
      assert html =~ Path.basename(tmp_dir)
    end

    test "remove button removes workspace", %{conn: conn, tmp_dir: tmp_dir} do
      {:ok, ws} = BoomLooper.WorkspaceRegistry.add(tmp_dir)

      {:ok, view, _html} = live(conn, "/")

      view
      |> element("button[phx-click='remove_workspace'][phx-value-id='#{ws.id}']")
      |> render_click()

      html = render(view)
      refute html =~ Path.basename(tmp_dir)
    end
  end

  describe "add workspace with tilde path" do
    test "expands ~ and navigates to workspace", %{conn: conn, tmp_dir: tmp_dir} do
      # Simulate a path with ~ by using the actual home dir
      home = System.user_home!()
      # Only run if tmp_dir is under home
      if String.starts_with?(tmp_dir, home) do
        tilde_path = String.replace_prefix(tmp_dir, home, "~")

        {:ok, view, _html} = live(conn, "/")

        view
        |> element("form[phx-submit='add_workspace']")
        |> render_submit(%{"path" => tilde_path})

        {path, _flash} = assert_redirect(view)
        assert path =~ "/w/"

        {:ok, _view, html} = live(conn, path)
        assert html =~ "New Agent"
      end
    end
  end

  describe "workspace with booting agents" do
    test "does not crash when agents lack bind_mount key", %{conn: conn, tmp_dir: tmp_dir} do
      {:ok, ws} = BoomLooper.WorkspaceRegistry.add(tmp_dir)

      # Register a booting agent (no bind_mount key in summary)
      id = "boot-ws-test-#{:rand.uniform(100_000)}"
      BoomLooper.ChatAgent.register_booting(id, "Test Agent", tmp_dir)

      on_exit(fn ->
        BoomLooper.ChatAgent.ensure_ets_table()
        :ets.delete(:chat_agents, id)
      end)

      # Should render without crashing
      {:ok, _view, html} = live(conn, "/")
      assert html =~ ws.name
    end
  end

  describe "empty state" do
    test "shows empty state message when no workspaces", %{conn: conn} do
      # Clear all workspaces (there may be some from other tests)
      for ws <- BoomLooper.WorkspaceRegistry.list() do
        BoomLooper.WorkspaceRegistry.remove(ws.id)
      end

      {:ok, _view, html} = live(conn, "/")
      assert html =~ "No workspaces yet"
    end
  end
end
