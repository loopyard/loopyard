defmodule BoomLooperWeb.SystemLiveTest do
  use BoomLooperWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  # CRITICAL: SystemLive must mount without blocking on Docker. The whole
  # point of the rewrite was that mount paints a skeleton instantly and
  # slow slices fill in via start_async/handle_async. These tests pin
  # that contract — if anyone reintroduces a synchronous shell-out in
  # mount, the timing assertion will fail loudly.

  describe "mount" do
    test "renders immediately with skeleton state — never blocks on docker", %{conn: conn} do
      {micros, {:ok, _view, html}} = :timer.tc(fn -> live(conn, "/system") end)

      # Mount + first render must be well under any docker shell-out cost
      # (`docker stats --no-stream` alone takes 1-2s). 500ms is generous;
      # the actual goal is <100ms but tests have setup overhead.
      assert micros < 500_000,
        "SystemLive mount took #{div(micros, 1000)}ms — synchronous slow call slipped in"

      assert html =~ "Host System"
      assert html =~ "BEAM VM"
      assert html =~ "Cluster"
    end

    test "shows breadcrumb back to root", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/system")
      assert has_element?(view, "a[href='/']")
    end

    test "shows drill-down links to subpages", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/system")
      assert has_element?(view, "a[href='/system/workspaces']")
      assert has_element?(view, "a[href='/system/docker']")
    end

    test "BEAM stats render in initial paint (no async, pure VM lookup)", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/system")
      # BEAM stats are populated synchronously from mount because they're
      # just :erlang.memory() calls. They should be in the very first HTML.
      assert html =~ "Memory"
      assert html =~ "Processes"
      assert html =~ "Schedulers"
    end
  end

  describe "reboot" do
    test "fires reboot event", %{conn: conn} do
      # Don't actually reboot — just verify the button is present.
      {:ok, view, _html} = live(conn, "/system")
      assert has_element?(view, "button[phx-click='reboot']")
    end
  end
end
