defmodule Loopyard.Tools.AgentFiles.ReadAgentFileTest do
  use ExUnit.Case

  alias Loopyard.Tools.AgentFiles.ReadAgentFile

  setup do
    id = "read-agent-file-test-#{System.unique_integer([:positive])}"

    :ets.insert(
      :chat_agents,
      {id,
       %{
         id: id,
         name: "Setup",
         agent_type: "setup",
         working_dir: "/tmp",
         workspace_id: "ws-test"
       }}
    )

    on_exit(fn -> :ets.delete(:chat_agents, id) end)
    {:ok, agent_id: id}
  end

  describe "execute/2" do
    test "reads a file from the agent folder", %{agent_id: id} do
      {:ok, contents} =
        ReadAgentFile.execute(%{agent_id: id, path: "setup_guide.md"}, %{})

      assert is_binary(contents)
      assert String.length(contents) > 0
    end

    test "reads a nested stack file", %{agent_id: id} do
      {:ok, contents} =
        ReadAgentFile.execute(%{agent_id: id, path: "stacks/rails.md"}, %{})

      assert is_binary(contents)
    end

    test "rejects path traversal with ..", %{agent_id: id} do
      {:error, reason} =
        ReadAgentFile.execute(%{agent_id: id, path: "../../secret.txt"}, %{})

      assert reason =~ "escapes"
    end

    test "rejects absolute paths", %{agent_id: id} do
      {:error, reason} =
        ReadAgentFile.execute(%{agent_id: id, path: "/etc/passwd"}, %{})

      assert reason =~ "relative"
    end

    test "returns error for missing file", %{agent_id: id} do
      {:error, reason} =
        ReadAgentFile.execute(%{agent_id: id, path: "not_a_real_file.md"}, %{})

      assert reason =~ "not found"
    end

    test "uses default agent when state has none" do
      id = "no-type-test-#{System.unique_integer([:positive])}"

      :ets.insert(:chat_agents, {id, %{id: id, name: "x"}})
      on_exit(fn -> :ets.delete(:chat_agents, id) end)

      # Default is coding; its folder has no other files
      {:error, reason} =
        ReadAgentFile.execute(%{agent_id: id, path: "setup_guide.md"}, %{})

      assert reason =~ "not found"
    end
  end
end
