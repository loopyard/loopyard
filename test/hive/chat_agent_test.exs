defmodule Hive.ChatAgentTest do
  use ExUnit.Case

  alias Hive.ChatAgent

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

  describe "get_state/1" do
    setup do
      id = "state-test-#{:rand.uniform(100_000)}"

      {:ok, _pid} =
        Hive.ChatAgentSupervisor.start_agent(
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
  end
end
