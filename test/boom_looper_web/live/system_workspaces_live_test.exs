defmodule BoomLooperWeb.SystemWorkspacesLiveTest do
  use BoomLooperWeb.ConnCase, async: false

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
      ws_count = length(BoomLooper.SystemStats.workspace_stats())
      if ws_count > 0 do
        assert html =~ "Group"
        assert html =~ "ServiceMgr"
      else
        assert html =~ "No workspaces registered"
      end
    end
  end
end
