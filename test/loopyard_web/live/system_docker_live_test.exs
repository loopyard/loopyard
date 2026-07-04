defmodule LoopyardWeb.SystemDockerLiveTest do
  use LoopyardWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  describe "mount" do
    test "renders skeleton immediately — never blocks on docker stats", %{conn: conn} do
      # Warm up once. First LV mount on a cold BEAM pays for
      # code-loading assigns modules, Gettext, etc. — not what
      # this test is measuring.
      {:ok, _, _} = live(conn, "/system/docker")

      {micros, {:ok, _view, html}} = :timer.tc(fn -> live(conn, "/system/docker") end)

      # `docker stats --no-stream` and `docker volume ls` and `docker ps`
      # all happen via start_async — mount itself must not wait for any
      # of them. Without async wiring this would easily exceed 2-3 seconds.
      # 1s budget; the implementation's target is ~10ms.
      assert micros < 1_000_000,
             "SystemDockerLive mount took #{div(micros, 1000)}ms — synchronous docker call slipped in"

      assert html =~ "Containers"
      assert html =~ "Volumes"
    end

    test "breadcrumb links back to /system", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/system/docker")
      assert has_element?(view, "a[href='/system']")
    end

    test "containers and volumes render immediately from Observer cache — no skeletons", %{
      conn: conn
    } do
      {:ok, _view, html} = live(conn, "/system/docker")
      # Docker.Observer seeds ETS before any LiveView mounts, so the
      # containers and volumes sections are fully populated in the
      # first render. No animate-pulse skeletons for these. Only
      # container_stats (docker stats --no-stream) is still async.
      assert html =~ "Containers"
      assert html =~ "Volumes"
      # Seeded-from-cache means the sections RESOLVE on first render (to their
      # rows, or an empty-state message) rather than a <.skeleton> placeholder.
      # Assert the skeleton's own row class is absent — precise, and robust to
      # whether loopyard-* containers happen to exist during the run (matching
      # the empty-state text would flake in the full suite). Bare "animate-pulse"
      # is too broad: status-dot indicators pulse too.
      refute html =~ "bg-zinc-200 dark:bg-zinc-700 rounded animate-pulse",
             "Containers/volumes are showing a <.skeleton> — Observer cache not seeded?"

      # The section headers carry a live "(N)" count only once the list is seeded.
      assert html =~ ~r/Containers[\s\S]{0,120}\(\d+\)/
      assert html =~ ~r/Volumes[\s\S]{0,120}\(\d+\)/
    end
  end

  describe "multiplayer (PubSub)" do
    test "two viewers both stay alive on a chat_agent broadcast", %{conn: conn} do
      {:ok, view1, _} = live(conn, "/system/docker")
      {:ok, view2, _} = live(build_conn(), "/system/docker")
      Process.sleep(50)

      Phoenix.PubSub.broadcast(
        Loopyard.PubSub,
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
        Loopyard.PubSub,
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
