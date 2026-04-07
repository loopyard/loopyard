defmodule BoomLooperWeb.SystemDockerLiveTest do
  use BoomLooperWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  describe "mount" do
    test "renders skeleton immediately — never blocks on docker stats", %{conn: conn} do
      {micros, {:ok, _view, html}} = :timer.tc(fn -> live(conn, "/system/docker") end)

      # `docker stats --no-stream` and `docker volume ls` and `docker ps`
      # all happen via start_async — mount itself must not wait for any
      # of them. Without async wiring this would easily exceed 2-3 seconds.
      assert micros < 500_000,
        "SystemDockerLive mount took #{div(micros, 1000)}ms — synchronous docker call slipped in"

      assert html =~ "Containers"
      assert html =~ "Volumes"
    end

    test "breadcrumb links back to /system", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/system/docker")
      assert has_element?(view, "a[href='/system']")
    end

    test "shows loading skeletons before async tasks complete", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/system/docker")
      # Skeleton rows have animate-pulse — they're our visible placeholder
      # while the async slices are in flight. If we accidentally synced
      # the loads back into mount, the html would jump straight to the
      # populated tables and this would fail.
      assert html =~ "animate-pulse"
    end
  end
end
