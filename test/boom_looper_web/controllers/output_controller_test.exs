defmodule BoomLooperWeb.OutputControllerTest do
  use BoomLooperWeb.ConnCase
  @moduletag timeout: 15_000

  describe "show/2" do
    setup do
      id = "output-test-#{:rand.uniform(100_000)}"
      tmp_dir = Path.join(System.tmp_dir!(), "output-#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)

      {:ok, _pid} =
        BoomLooper.TestHelpers.start_agent(
          id: id,
          name: "Output Test",
          working_dir: tmp_dir,
          started_by: "test"
        )

      # Insert a message directly via append_message_ets — synchronous
      # with the FIFO mailbox, so no Process.sleep needed and no flake
      # waiting for the CLI stream task to settle.
      BoomLooper.ChatAgent.append_message_ets(id, %{
        role: :user,
        content: "test message",
        timestamp: DateTime.utc_now()
      })

      on_exit(fn ->
        try do
          BoomLooper.ChatAgent.stop_agent(id)
        catch
          :exit, _ -> :ok
        end

        File.rm_rf!(tmp_dir)
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
