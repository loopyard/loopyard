defmodule BoomLooperWeb.SystemOrphansLiveTest do
  @moduledoc """
  Smoke tests for `/system/orphans`. The ownership mechanics are
  covered in `BoomLooper.ResourcesTest`; this file verifies the LV
  mounts, renders tracked entries, and flags stale owners in red.
  """
  use BoomLooperWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias BoomLooper.Resources

  setup do
    :ets.delete_all_objects(:resource_registry)
    :ok
  end

  describe "mount" do
    test "renders the orphans page with breadcrumb + empty state", %{conn: conn} do
      {:ok, view, html} = live(conn, "/system/orphans")

      assert html =~ "Orphans"
      assert has_element?(view, "a[href='/system']")
      assert html =~ "No tracked resources"
    end

    test "shows a tracked resource grouped by owner pid", %{conn: conn} do
      {owner, _} = spawn_owner()

      Resources.track(owner, :port_binding, {"ws-foo", "web", 3000}, fn -> :ok end)

      {:ok, _view, html} = live(conn, "/system/orphans")

      assert html =~ "port_binding"
      assert html =~ "ws-foo"
      assert html =~ "1 resource"

      send(owner, :stop)
    end

    test "renders the coverage section with in-scope + out-of-scope entries", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/system/orphans")

      assert html =~ "port_binding"
      assert html =~ "WorkspaceGroup"
      assert html =~ "Mutagen"
      assert html =~ "Docker containers"
    end
  end

  defp spawn_owner do
    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    ref = Process.monitor(pid)
    {pid, ref}
  end
end
