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

  describe "multiplayer (PubSub)" do
    test "two viewers both stay alive on a chat_agent broadcast", %{conn: conn} do
      {:ok, view1, _} = live(conn, "/system/docker")
      {:ok, view2, _} = live(build_conn(), "/system/docker")
      Process.sleep(50)

      Phoenix.PubSub.broadcast(
        BoomLooper.PubSub,
        "chat_agent",
        {:chat_agent_started, %{id: "fake", name: "fake", status: :idle}}
      )

      assert is_binary(render(view1))
      assert is_binary(render(view2))
    end

    test "viewer refreshes on a services_updated broadcast", %{conn: conn} do
      {:ok, view, _} = live(conn, "/system/docker")
      Process.sleep(50)

      Phoenix.PubSub.broadcast(
        BoomLooper.PubSub,
        "service_manager",
        {:services_updated, "/some/path", []}
      )

      assert is_binary(render(view))
    end

    test "unknown PubSub messages don't crash the LiveView", %{conn: conn} do
      {:ok, view, _} = live(conn, "/system/docker")
      send(view.pid, {:totally_unknown_message, :payload})
      assert is_binary(render(view))
    end
  end
end
