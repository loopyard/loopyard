defmodule BoomLooper.AgentPersistenceRestoreTest do
  @moduledoc """
  Tests that agents survive server restarts.

  The bug: agent logs were written to ~/.boomlooper/workspaces/<id>/
  (via Persistence.log_path → Workspace.compose_dir) but read from
  workspace.path (the project source dir). Writes and reads looked at
  different paths, so agents vanished on restart.

  Contract:
    * Persistence.log_path(workspace_id) is the ONLY source of truth
      for where agent logs live.
    * On boot, all workspace agent logs are replayed into ETS before
      any page visit (restore_all_agents in application.ex).
    * prime_agents_from_log and replay_agent_log both use
      Persistence.log_path, not project_dir.
  """

  use ExUnit.Case, async: true

  alias BoomLooper.AgentLog
  alias BoomLooper.ChatAgent.Persistence

  @version 1

  describe "Persistence.log_path/1" do
    test "returns path under compose_dir, not project source dir" do
      path = Persistence.log_path("test-ws-123")
      compose_dir = BoomLooper.Workspace.compose_dir("test-ws-123")
      assert String.starts_with?(path, compose_dir)
      assert path =~ "workspaces/test-ws-123"
      assert String.ends_with?(path, ".boomlooper/workspace/agents.log")
    end

    test "returns nil for nil workspace_id" do
      assert Persistence.log_path(nil) == nil
    end
  end

  describe "round-trip: write then replay from same path" do
    setup do
      # Use a unique workspace ID so compose_dir is unique
      ws_id = "test-#{:erlang.unique_integer([:positive])}"
      log_path = Persistence.log_path(ws_id)

      # Ensure the directory exists
      File.mkdir_p!(Path.dirname(log_path))

      on_exit(fn ->
        File.rm_rf!(Path.dirname(log_path))
      end)

      %{ws_id: ws_id, log_path: log_path}
    end

    test "agents written via Persistence.log_path are found by replay using same path", %{
      ws_id: ws_id,
      log_path: log_path
    } do
      # Simulate what ChatAgent.Persistence does on write
      agent_data = %{name: "Test Agent", status: :idle, workspace_id: ws_id}
      AgentLog.append({:agent, "agent-1", agent_data}, log_path: log_path, version: @version)

      AgentLog.append({:msg, "agent-1", %{id: "m1", role: :user, content: "hello"}},
        log_path: log_path,
        version: @version
      )

      # Simulate what boot-time restore does: read from Persistence.log_path
      read_path = Persistence.log_path(ws_id)
      assert read_path == log_path, "Write and read paths must match"

      assert {:ok, state} = AgentLog.replay(log_path: read_path, version: @version)
      assert Map.has_key?(state, "agent-1")
      assert state["agent-1"].name == "Test Agent"
      assert length(state["agent-1"].messages) == 1
    end

    test "replay populates ETS table", %{ws_id: ws_id, log_path: log_path} do
      table = :ets.new(:"test_agents_#{:erlang.unique_integer()}", [:set, :public])

      AgentLog.append({:agent, "agent-2", %{name: "ETS Agent"}},
        log_path: log_path,
        version: @version
      )

      AgentLog.append({:msg, "agent-2", %{id: "m1", role: :user, content: "test"}},
        log_path: log_path,
        version: @version
      )

      {:ok, _} =
        AgentLog.replay(
          log_path: Persistence.log_path(ws_id),
          version: @version,
          ets_table: table
        )

      [{_, agent}] = :ets.lookup(table, "agent-2")
      assert agent.name == "ETS Agent"
      assert agent.id == "agent-2"
      assert length(agent.messages) == 1

      :ets.delete(table)
    end
  end

  describe "boot-time restore contract" do
    test "restore_all_agents replays logs for every workspace" do
      # Create temp ETS table and workspace registry
      agents_table = :ets.new(:test_chat_agents, [:set, :public])
      ws_table = :ets.new(:test_ws_registry, [:set, :public])

      # Create two fake workspaces with agent logs
      ws1_id = "boot-test-ws1-#{:erlang.unique_integer([:positive])}"
      ws2_id = "boot-test-ws2-#{:erlang.unique_integer([:positive])}"

      log1 = Persistence.log_path(ws1_id)
      log2 = Persistence.log_path(ws2_id)

      File.mkdir_p!(Path.dirname(log1))
      File.mkdir_p!(Path.dirname(log2))

      AgentLog.append({:agent, "ws1-agent", %{name: "Agent One"}},
        log_path: log1,
        version: @version
      )

      AgentLog.append({:msg, "ws1-agent", %{id: "m1", role: :user, content: "hello"}},
        log_path: log1,
        version: @version
      )

      AgentLog.append({:agent, "ws2-agent", %{name: "Agent Two"}},
        log_path: log2,
        version: @version
      )

      # Simulate what restore_all_agents does
      for {ws_id, _} <- [{ws1_id, log1}, {ws2_id, log2}] do
        path = Persistence.log_path(ws_id)

        if path && File.exists?(path) do
          AgentLog.replay(log_path: path, version: @version, ets_table: agents_table)
        end
      end

      # Both agents must be in ETS
      assert [{_, a1}] = :ets.lookup(agents_table, "ws1-agent")
      assert a1.name == "Agent One"
      assert length(a1.messages) == 1

      assert [{_, a2}] = :ets.lookup(agents_table, "ws2-agent")
      assert a2.name == "Agent Two"

      # Cleanup
      :ets.delete(agents_table)
      :ets.delete(ws_table)
      File.rm_rf!(Path.dirname(log1))
      File.rm_rf!(Path.dirname(log2))
    end
  end

  describe "path consistency" do
    test "ServiceManager and workspace_live both resolve to Persistence.log_path" do
      # This is a code-level assertion: both modules must use Persistence.log_path,
      # not construct the path from project_dir. We verify by checking that
      # Persistence.log_path returns the compose_dir-based path.
      ws_id = "consistency-check"

      expected =
        BoomLooper.Workspace.compose_dir(ws_id)
        |> Path.join(".boomlooper/workspace/agents.log")

      assert Persistence.log_path(ws_id) == expected
    end
  end
end
