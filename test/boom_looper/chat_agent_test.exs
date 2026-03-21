defmodule BoomLooper.ChatAgentTest do
  use ExUnit.Case

  alias BoomLooper.ChatAgent

  describe "list_agents/0" do
    test "returns a list" do
      assert is_list(ChatAgent.list_agents())
    end
  end

  describe "subscribe/0" do
    test "subscribes to the global chat agents topic" do
      assert :ok = ChatAgent.subscribe()
    end
  end

  describe "subscribe/1 and unsubscribe/1" do
    test "subscribes and unsubscribes to a specific agent" do
      assert :ok = ChatAgent.subscribe("test-id")
      assert :ok = ChatAgent.unsubscribe("test-id")
    end
  end

  describe "restart_session/1" do
    setup do
      id = "restart-test-#{:rand.uniform(100_000)}"

      {:ok, _pid} =
        BoomLooper.TestHelpers.start_agent(
          id: id,
          name: "Restart Test",
          working_dir: File.cwd!(),
          started_by: "test"
        )

      on_exit(fn ->
        try do
          ChatAgent.stop_agent(id)
        catch
          :exit, _ -> :ok
        end

        Process.sleep(50)
      end)

      %{id: id}
    end

    test "restart_session preserves agent state and adds system message", %{id: id} do
      ChatAgent.subscribe(id)
      ChatAgent.subscribe()

      # Agent should be idle before restart
      state_before = ChatAgent.get_state(id)
      assert state_before.status == :idle

      ChatAgent.restart_session(id)

      # Should receive a system message about the restart
      assert_receive {:chat_message, ^id, %{role: :system, content: "CLI session restarted"}}, 5000

      # Agent should still be idle after restart
      state_after = ChatAgent.get_state(id)
      assert state_after.status == :idle
      assert state_after.name == "Restart Test"
      assert state_after.id == id
    end
  end

  describe "get_state/1" do
    setup do
      id = "state-test-#{:rand.uniform(100_000)}"

      {:ok, _pid} =
        BoomLooper.TestHelpers.start_agent(
          id: id,
          name: "State Test",
          working_dir: File.cwd!(),
          started_by: "test"
        )

      on_exit(fn ->
        try do
          ChatAgent.stop_agent(id)
        catch
          :exit, _ -> :ok
        end

        Process.sleep(50)
      end)

      %{id: id}
    end

    test "returns agent summary with all fields", %{id: id} do
      state = ChatAgent.get_state(id)

      assert state.id == id
      assert state.name == "State Test"
      assert state.working_dir == File.cwd!()
      assert state.started_by == "test"
      assert state.status == :idle
      assert state.messages == []
      assert state.tool_calls == 0
      assert state.errors == 0
      assert %DateTime{} = state.started_at
      assert %DateTime{} = state.last_activity_at
    end

    test "messages have unique IDs after send", %{id: id} do
      ChatAgent.send_message(id, "hello")
      Process.sleep(200)

      state = ChatAgent.get_state(id)
      # Should have at least the user message
      user_msgs = Enum.filter(state.messages, &(&1.role == :user))
      assert length(user_msgs) >= 1

      # Every message must have an :id
      for msg <- state.messages do
        assert msg[:id] != nil, "Message missing :id — role: #{msg.role}, content: #{inspect(String.slice(msg.content || "", 0..30))}"
      end

      # IDs must be unique
      ids = Enum.map(state.messages, & &1[:id]) |> Enum.reject(&is_nil/1)
      assert ids == Enum.uniq(ids), "Duplicate message IDs found"
    end

    test "get_message returns message by ID", %{id: id} do
      ChatAgent.send_message(id, "test lookup")
      Process.sleep(200)

      state = ChatAgent.get_state(id)
      msg = Enum.find(state.messages, &(&1.role == :user))

      assert msg[:id] != nil
      found = ChatAgent.get_message(id, msg.id)
      assert found != nil
      assert found.content == "test lookup"
    end

    test "get_message returns nil for unknown ID", %{id: id} do
      assert ChatAgent.get_message(id, "nonexistent") == nil
    end
  end
end
