defmodule HiveWeb.SystemLiveTest do
  use HiveWeb.ConnCase

  import Phoenix.LiveViewTest

  describe "mount" do
    test "renders the system page", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/system")

      assert html =~ "System"
      assert html =~ "Host System"
      assert html =~ "Hive App"
      assert html =~ "BEAM Memory"
    end

    test "shows back link to chat", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/system")
      assert has_element?(view, "a[href='/']")
    end
  end

  describe "agent resources" do
    setup %{conn: conn} do
      id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

      {:ok, _pid} =
        Hive.ChatAgentSupervisor.start_agent(
          id: id,
          name: "System Test Agent",
          working_dir: File.cwd!(),
          started_by: "test",
          docker_ready: true
        )

      on_exit(fn ->
        try do
          Hive.ChatAgent.stop_agent(id)
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
  end
end
