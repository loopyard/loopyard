defmodule BoomLooper.Tools.AgentsTest do
  use ExUnit.Case

  alias BoomLooper.Tools.Agents

  describe "module structure" do
    test "is a valid MCP server" do
      assert ClaudeCode.MCP.Server.sdk_server?(Agents)
    end

    test "has correct server name and 6 tools" do
      info = Agents.__tool_server__()
      assert info.name == "boom-looper-agents"
      assert length(info.tools) == 6
    end

    test "tool names match expected" do
      tool_names = Agents.__tool_server__().tools |> Enum.map(& &1.__tool_name__())
      assert "list_agents" in tool_names
      assert "spawn_agent" in tool_names
      assert "send_message_to_agent" in tool_names
      assert "read_agent_chat" in tool_names
      assert "stop_agent" in tool_names
    end
  end

  describe "do_list/0" do
    test "returns a list" do
      agents = Agents.do_list()
      assert is_list(agents)
    end
  end

  describe "do_spawn/2" do
    # do_spawn creates real Docker containers
    @describetag :docker

    test "spawns an agent and returns id and name" do
      assert {:ok, %{id: id, name: "Test Spawn"}} =
               Agents.do_spawn("Test Spawn", File.cwd!())

      assert is_binary(id)

      # Verify it shows up in list
      agents = Agents.do_list()
      assert Enum.any?(agents, &(&1.id == id))

      # Clean up
      Agents.do_stop(id)
      Process.sleep(100)
    end
  end

  describe "do_stop/1" do
    @describetag :docker

    test "stops a running agent" do
      {:ok, %{id: id}} = Agents.do_spawn("To Stop", File.cwd!())
      assert {:ok, _} = Agents.do_stop(id)
      Process.sleep(100)
    end

    test "returns error for non-existent agent" do
      assert {:error, _} = Agents.do_stop("nonexistent")
    end
  end

  describe "do_send_message/2" do
    test "returns error for non-existent agent" do
      assert {:error, _} = Agents.do_send_message("nonexistent", "hello")
    end
  end

  describe "do_read_chat/2" do
    test "returns error for non-existent agent" do
      assert {:error, msg} = Agents.do_read_chat("nonexistent")
      assert msg =~ "not found"
    end

    test "returns chat history for a running agent" do
      id = "read-chat-test-#{:rand.uniform(100_000)}"

      {:ok, _pid} = BoomLooper.TestHelpers.start_agent(
        id: id,
        name: "Chat Reader Test",
        working_dir: File.cwd!(),
        bind_mount: File.cwd!(),
        started_by: "test"
      )

      # Send a message so there's history
      BoomLooper.ChatAgent.send_message(id, "hello from test")
      Process.sleep(200)

      {:ok, result} = Agents.do_read_chat(id)
      assert result =~ "Chat Reader Test"
      assert result =~ "hello from test"
      assert result =~ "[USER]"

      # Clean up
      try do
        BoomLooper.ChatAgent.stop_agent(id)
      catch
        :exit, _ -> :ok
      end
      Process.sleep(50)
    end

    test "respects tail option" do
      id = "tail-test-#{:rand.uniform(100_000)}"

      {:ok, _pid} = BoomLooper.TestHelpers.start_agent(
        id: id,
        name: "Tail Test",
        working_dir: File.cwd!(),
        bind_mount: File.cwd!(),
        started_by: "test"
      )

      # Send multiple messages
      for i <- 1..5 do
        BoomLooper.ChatAgent.send_message(id, "message #{i}")
        Process.sleep(100)
      end

      {:ok, result} = Agents.do_read_chat(id, %{tail: 2})
      # Should only have the last 2 messages worth of content
      lines = String.split(result, "\n") |> Enum.filter(&String.starts_with?(&1, "["))
      assert length(lines) <= 2

      try do
        BoomLooper.ChatAgent.stop_agent(id)
      catch
        :exit, _ -> :ok
      end
      Process.sleep(50)
    end
  end
end
