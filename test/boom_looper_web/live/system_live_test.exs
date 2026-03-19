defmodule BoomLooperWeb.SystemLiveTest do
  use BoomLooperWeb.ConnCase

  import Phoenix.LiveViewTest

  # SystemLive calls docker stats on mount, which is slow and can hang
  @moduletag :docker

  describe "mount" do
    test "renders the system page", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/system")

      assert html =~ "System"
      assert html =~ "Host System"
      assert html =~ "BoomLooper App"
      assert html =~ "BEAM Memory"
    end

    test "shows back link to chat", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/system")
      assert has_element?(view, "a[href='/']")
    end
  end

  describe "service containers section" do
    test "renders service containers section", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/system")
      assert html =~ "Service Containers"
    end
  end

  describe "agent resources" do
    setup %{conn: conn} do
      id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

      {:ok, _pid} =
        BoomLooper.ChatAgentSupervisor.start_agent(
          id: id,
          name: "System Test Agent",
          working_dir: File.cwd!(),
          started_by: "test"
        )

      on_exit(fn ->
        try do
          BoomLooper.ChatAgent.stop_agent(id)
        catch
          :exit, _ -> :ok
        end

        Process.sleep(50)
      end)

      %{conn: conn, agent_id: id}
    end

    test "shows per-agent resource breakdown", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/system")
      assert html =~ "System Test Agent"
      assert html =~ "GenServer"
      assert html =~ "Docker Container"
      assert html =~ "Claude CLI"
    end

    test "shows kill button for active agents", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/system")
      assert has_element?(view, "button[phx-click='kill_container']")
    end

    test "shows restart CLI button for active agents", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/system")
      assert has_element?(view, "button[phx-click='restart_session']")
    end
  end
end
