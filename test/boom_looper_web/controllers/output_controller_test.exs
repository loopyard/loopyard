defmodule BoomLooperWeb.OutputControllerTest do
  use BoomLooperWeb.ConnCase

  describe "show/2" do
    setup do
      id = "output-test-#{:rand.uniform(100_000)}"

      {:ok, _pid} =
        BoomLooper.TestHelpers.start_agent(
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

    test "returns message content with valid URL", %{conn: conn, agent_id: id} do
      state = BoomLooper.ChatAgent.get_state(id)
      msg = hd(state.messages)
      url = BoomLooperWeb.OutputController.raw_url(id, msg.id)
      conn = get(conn, url)
      assert response(conn, 200) == "test message"
      assert response_content_type(conn, :text)
    end

    test "returns 404 for unknown message ID", %{conn: conn, agent_id: id} do
      url = BoomLooperWeb.OutputController.raw_url(id, "nonexistent")
      conn = get(conn, url)
      assert response(conn, 404)
    end

    test "returns 404 for unknown agent ID", %{conn: conn} do
      conn = get(conn, "/messages/nonexistent/0/raw")
      assert response(conn, 404)
    end
  end
end
