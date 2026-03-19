defmodule BoomLooperWeb.OutputControllerTest do
  use BoomLooperWeb.ConnCase

  describe "show/2" do
    setup do
      id = "output-test-#{:rand.uniform(100_000)}"

      {:ok, _pid} =
        BoomLooper.ChatAgentSupervisor.start_agent(
          id: id,
          name: "Output Test",
          working_dir: File.cwd!(),
          started_by: "test"
        )

      # Send a message so the agent has messages in its state
      BoomLooper.ChatAgent.send_message(id, "test message")
      Process.sleep(100)

      on_exit(fn ->
        try do
          BoomLooper.ChatAgent.stop_agent(id)
        catch
          :exit, _ -> :ok
        end
      end)

      %{agent_id: id}
    end

    test "returns 403 without token", %{conn: conn, agent_id: id} do
      conn = get(conn, "/w/test/chat/#{id}/msg/0")
      assert response(conn, 403) =~ "Missing token"
    end

    test "returns 403 with invalid token", %{conn: conn, agent_id: id} do
      conn = get(conn, "/w/test/chat/#{id}/msg/0?token=bogus")
      assert response(conn, 403) =~ "expired or invalid"
    end

    test "returns message content with valid signed URL", %{conn: conn, agent_id: id} do
      # The first message should be the user message "test message"
      url = BoomLooperWeb.OutputController.signed_url("test", id, 0)
      conn = get(conn, url)
      assert response(conn, 200) == "test message"
      assert response_content_type(conn, :text)
    end

    test "returns 404 for out of bounds index", %{conn: conn, agent_id: id} do
      url = BoomLooperWeb.OutputController.signed_url("test", id, 999)
      conn = get(conn, url)
      assert response(conn, 404)
    end
  end
end
