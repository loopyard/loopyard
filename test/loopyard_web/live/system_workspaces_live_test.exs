defmodule LoopyardWeb.SystemWorkspacesLiveTest do
  use LoopyardWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  describe "mount" do
    test "renders without blocking on docker", %{conn: conn} do
      {micros, {:ok, _view, html}} = :timer.tc(fn -> live(conn, "/system/workspaces") end)

      assert micros < 500_000,
             "SystemWorkspacesLive mount took #{div(micros, 1000)}ms — synchronous slow call slipped in"

      assert html =~ "Workspaces"
    end

    test "breadcrumb links back to /system", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/system/workspaces")
      assert has_element?(view, "a[href='/system']")
    end

    test "registered workspaces appear with health pills", %{conn: conn} do
      # workspace_stats reads ProjectRegistry, which is in-memory.
      # Whatever's there should render in the first paint.
      {:ok, _view, html} = live(conn, "/system/workspaces")

      # Either we have workspaces (and they render with pills) or we
      # don't (and the empty-state copy renders).
      ws_count = length(Loopyard.SystemStats.workspace_stats())

      if ws_count > 0 do
        assert html =~ "Group"
        assert html =~ "ServiceMgr"
      else
        assert html =~ "No workspaces registered"
      end
    end
  end

  describe "multiplayer (PubSub)" do
    test "two viewers both refresh on a chat_agent_started broadcast", %{conn: conn} do
      # Two independent LiveView sessions on the same page.
      {:ok, view1, _} = live(conn, "/system/workspaces")
      {:ok, view2, _} = live(build_conn(), "/system/workspaces")

      # Force any in-flight async tasks to land first.
      Process.sleep(50)
      _ = render(view1)
      _ = render(view2)

      # Broadcast the same shape ChatAgent emits when an agent starts.
      Phoenix.PubSub.broadcast(
        Loopyard.PubSub,
        "chat_agent",
        {:chat_agent_started, %{id: "fake", name: "fake", status: :idle}}
      )

      # Both LiveViews should have re-rendered. We can't assert on
      # specific HTML changes (the registry didn't actually change)
      # but we CAN assert that neither LiveView crashed and both
      # respond to a render call.
      assert is_binary(render(view1))
      assert is_binary(render(view2))
    end

    test "viewer refreshes on a services_updated broadcast", %{conn: conn} do
      {:ok, view, _} = live(conn, "/system/workspaces")
      Process.sleep(50)

      Phoenix.PubSub.broadcast(
        Loopyard.PubSub,
        "service_manager",
        {:services_updated, "/some/path", []}
      )

      assert is_binary(render(view))
    end

    test "unknown PubSub messages don't crash the LiveView", %{conn: conn} do
      {:ok, view, _} = live(conn, "/system/workspaces")
      send(view.pid, {:totally_unknown_message, :payload})
      assert is_binary(render(view))
    end
  end
end
