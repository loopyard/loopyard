defmodule BoomLooper.ChatAgent.PersistenceTest do
  use ExUnit.Case

  alias BoomLooper.ChatAgent.Persistence

  describe "log_path/1" do
    test "returns nil for nil workspace_id" do
      assert Persistence.log_path(nil) == nil
    end

    test "returns a path ending in agents.log for a workspace_id" do
      path = Persistence.log_path("test-workspace-123")
      assert is_binary(path)
      assert String.ends_with?(path, "agents.log")
      assert path =~ "test-workspace-123"
      assert path =~ ".boomlooper/workspace"
    end

    test "paths are consistent for the same workspace_id" do
      path1 = Persistence.log_path("same-id")
      path2 = Persistence.log_path("same-id")
      assert path1 == path2
    end

    test "different workspace_ids produce different paths" do
      path1 = Persistence.log_path("workspace-a")
      path2 = Persistence.log_path("workspace-b")
      refute path1 == path2
    end
  end

  describe "persist_message/2" do
    test "returns :ok when workspace_id is nil" do
      state = %{workspace_id: nil, id: "agent-1"}
      assert :ok == Persistence.persist_message(state, %{role: :user, content: "hi"})
    end
  end

  describe "persist_message_update/3" do
    test "returns :ok when workspace_id is nil" do
      state = %{workspace_id: nil, id: "agent-1"}
      assert :ok == Persistence.persist_message_update(state, "msg-1", %{content: "updated"})
    end
  end

  describe "persist_agent/2" do
    test "returns :ok when workspace_id is nil" do
      state = %{workspace_id: nil, id: "agent-1"}
      summary_fn = fn _s -> %{id: "agent-1", messages: []} end
      assert :ok == Persistence.persist_agent(state, summary_fn)
    end
  end
end
