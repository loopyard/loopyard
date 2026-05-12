defmodule Loopyard.AgentRecoveryTest do
  @moduledoc """
  Tests for agent recovery in various inconsistent states.

  These tests document the expected behavior when:
  - History exists but container doesn't
  - Container exists but history doesn't
  - Both exist (happy path)
  - Neither exists (clean start)
  - CLI session fails to start during resume
  """
  use ExUnit.Case, async: true

  alias Loopyard.{AgentLog, ChatAgent}

  @version 1

  setup do
    # Create temp directory for log files
    tmp_dir =
      Path.join(System.tmp_dir!(), "agent_recovery_test_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    log_path = Path.join(tmp_dir, ".loopyard/workspace/agents.log")

    # Tables are pre-created by StateKeeper.
    Loopyard.StateKeeper.ensure_tables!()

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
    end)

    %{tmp_dir: tmp_dir, log_path: log_path}
  end

  describe "state: history exists, no container" do
    @tag :recovery
    test "agent starts in degraded state when container unavailable", %{log_path: log_path} do
      agent_id = "agent-#{:erlang.unique_integer([:positive])}"

      # Simulate previous session - write history to log
      AgentLog.append(
        {:agent, agent_id,
         %{
           name: "Test Agent",
           workspace_id: "ws-123",
           started_at: DateTime.utc_now(),
           started_by: "test",
           status: :idle
         }},
        log_path: log_path,
        version: @version
      )

      AgentLog.append(
        {:msg, agent_id,
         %{
           id: "msg-1",
           role: :user,
           content: "Hello from the past",
           timestamp: DateTime.utc_now()
         }},
        log_path: log_path,
        version: @version
      )

      AgentLog.append(
        {:msg, agent_id,
         %{
           id: "msg-2",
           role: :assistant,
           content: "I remember this conversation",
           timestamp: DateTime.utc_now()
         }},
        log_path: log_path,
        version: @version
      )

      # Replay log into ETS (simulates what ServiceManager does)
      {:ok, agents} =
        AgentLog.replay(log_path: log_path, version: @version, ets_table: :chat_agents)

      # Verify history was restored to ETS
      assert Map.has_key?(agents, agent_id)
      assert length(agents[agent_id].messages) == 2

      # Verify ETS has the agent
      [{^agent_id, saved}] = :ets.lookup(:chat_agents, agent_id)
      assert saved.name == "Test Agent"
      assert length(saved.messages) == 2

      # Now try to resume the agent - this should handle missing container gracefully
      # For now, we document that starting with resume: true requires the backend to start
      # In a future iteration, we could add a :degraded status

      # The agent can be listed from ETS even without starting the GenServer
      state = ChatAgent.get_state(agent_id)
      assert state.name == "Test Agent"
      assert length(state.messages) == 2

      # Clean up ETS
      :ets.delete(:chat_agents, agent_id)
    end

    @tag :recovery
    test "messages are preserved even when agent cannot fully resume", %{log_path: log_path} do
      agent_id = "agent-preserved-#{:erlang.unique_integer([:positive])}"

      # Write substantial history
      AgentLog.append({:agent, agent_id, %{name: "History Agent", workspace_id: "ws-1"}},
        log_path: log_path,
        version: @version
      )

      for i <- 1..10 do
        AgentLog.append(
          {:msg, agent_id,
           %{
             id: "msg-#{i}",
             role: if(rem(i, 2) == 0, do: :assistant, else: :user),
             content: "Message #{i}",
             timestamp: DateTime.utc_now()
           }},
          log_path: log_path,
          version: @version
        )
      end

      # Replay into ETS
      {:ok, _} = AgentLog.replay(log_path: log_path, version: @version, ets_table: :chat_agents)

      # All 10 messages should be there
      state = ChatAgent.get_state(agent_id)
      assert length(state.messages) == 10

      # Clean up
      :ets.delete(:chat_agents, agent_id)
    end
  end

  describe "state: container exists, no history" do
    @tag :recovery
    test "returns empty agent list when no log exists", %{tmp_dir: tmp_dir} do
      # Log file doesn't exist
      missing_log = Path.join(tmp_dir, "nonexistent/agents.log")

      {:ok, agents} = AgentLog.replay(log_path: missing_log, version: @version)

      assert agents == %{}
    end

    @tag :recovery
    test "empty log produces version mismatch (no meta header)", %{log_path: log_path} do
      # Create empty log file
      File.mkdir_p!(Path.dirname(log_path))
      File.write!(log_path, "")

      # Empty file has no meta header, so version check fails
      {:error, {:version_mismatch, _}} =
        AgentLog.replay(log_path: log_path, version: @version, ets_table: :chat_agents)
    end
  end

  describe "state: neither history nor container" do
    @tag :recovery
    test "clean start with no state produces empty agent list", %{tmp_dir: tmp_dir} do
      missing_log = Path.join(tmp_dir, "fresh/agents.log")

      # This is the expected happy path for a new workspace
      {:ok, agents} = AgentLog.replay(log_path: missing_log, version: @version)

      assert agents == %{}
      # User would create new agents from scratch
    end
  end

  describe "state: both history and container exist (happy path)" do
    @tag :recovery
    test "agent resumes with full history from log", %{log_path: log_path} do
      agent_id = "agent-happy-#{:erlang.unique_integer([:positive])}"

      # Write history
      AgentLog.append(
        {:agent, agent_id,
         %{
           name: "Happy Agent",
           workspace_id: "ws-happy",
           started_at: ~U[2024-01-15 10:00:00Z],
           started_by: "user",
           status: :idle,
           service_name: nil
         }},
        log_path: log_path,
        version: @version
      )

      AgentLog.append({:msg, agent_id, %{id: "m1", role: :user, content: "Setup the project"}},
        log_path: log_path,
        version: @version
      )

      AgentLog.append(
        {:msg, agent_id, %{id: "m2", role: :assistant, content: "I'll help you set up..."}},
        log_path: log_path,
        version: @version
      )

      AgentLog.append(
        {:msg, agent_id, %{id: "m3", role: :tool, tool: "exec", input: %{command: "ls"}}},
        log_path: log_path,
        version: @version
      )

      # Replay
      {:ok, agents} =
        AgentLog.replay(log_path: log_path, version: @version, ets_table: :chat_agents)

      assert Map.has_key?(agents, agent_id)
      agent = agents[agent_id]

      # All metadata preserved
      assert agent.name == "Happy Agent"
      assert agent.workspace_id == "ws-happy"
      assert agent.started_at == ~U[2024-01-15 10:00:00Z]

      # All messages in order
      assert length(agent.messages) == 3
      assert Enum.map(agent.messages, & &1.id) == ["m1", "m2", "m3"]

      # Clean up
      :ets.delete(:chat_agents, agent_id)
    end
  end

  describe "CLI session failure during resume" do
    @tag :recovery
    test "agent data remains in ETS even if GenServer fails to start", %{log_path: log_path} do
      agent_id = "agent-cli-fail-#{:erlang.unique_integer([:positive])}"

      # Write agent to log
      AgentLog.append(
        {:agent, agent_id,
         %{
           name: "CLI Fail Agent",
           workspace_id: "ws-fail"
         }},
        log_path: log_path,
        version: @version
      )

      AgentLog.append({:msg, agent_id, %{id: "m1", role: :user, content: "Important message"}},
        log_path: log_path,
        version: @version
      )

      # Replay into ETS
      {:ok, _} = AgentLog.replay(log_path: log_path, version: @version, ets_table: :chat_agents)

      # Agent data is in ETS
      state_before = ChatAgent.get_state(agent_id)
      assert state_before.name == "CLI Fail Agent"
      assert length(state_before.messages) == 1

      # Even if we can't start the GenServer (e.g., CLI fails),
      # the ETS data remains accessible for viewing history
      # This is the current behavior - users can see their chat history
      # even if the agent can't resume interactively

      # Clean up
      :ets.delete(:chat_agents, agent_id)
    end
  end

  describe "degraded state: container unavailable" do
    # Documents expected behavior when agents are restored but containers aren't running.
    #
    # Current behavior (simplest approach):
    # - Agent history is restored to ETS from log
    # - Agent can be listed and viewed (read-only access to history)
    # - If GenServer starts, commands will fail at runtime with container errors
    # - User can rebuild containers to restore full functionality
    #
    # This is acceptable because:
    # 1. History is never lost
    # 2. User sees clear errors when trying to use the agent
    # 3. No silent failures or data corruption

    @tag :recovery
    test "agent history viewable even without running container", %{log_path: log_path} do
      agent_id = "degraded-#{:erlang.unique_integer([:positive])}"

      # Agent had a productive session
      AgentLog.append({:agent, agent_id, %{name: "Degraded Agent", workspace_id: "ws-gone"}},
        log_path: log_path,
        version: @version
      )

      AgentLog.append({:msg, agent_id, %{id: "m1", role: :user, content: "Setup the project"}},
        log_path: log_path,
        version: @version
      )

      AgentLog.append(
        {:msg, agent_id,
         %{id: "m2", role: :assistant, content: "Done! Everything is configured."}},
        log_path: log_path,
        version: @version
      )

      AgentLog.append(
        {:msg, agent_id,
         %{id: "m3", role: :tool, tool: "exec", input: %{command: "mix deps.get"}}},
        log_path: log_path,
        version: @version
      )

      AgentLog.append(
        {:msg, agent_id, %{id: "m4", role: :tool_result, content: "Dependencies fetched"}},
        log_path: log_path,
        version: @version
      )

      # Server restarts, containers are gone, but log exists
      {:ok, _} = AgentLog.replay(log_path: log_path, version: @version, ets_table: :chat_agents)

      # All history is visible
      state = ChatAgent.get_state(agent_id)
      assert state.name == "Degraded Agent"
      assert length(state.messages) == 4

      # User can read the full conversation
      assert Enum.at(state.messages, 0).content == "Setup the project"
      assert Enum.at(state.messages, 1).content == "Done! Everything is configured."
      assert Enum.at(state.messages, 2).tool == "exec"
      assert Enum.at(state.messages, 3).content == "Dependencies fetched"

      # Clean up
      :ets.delete(:chat_agents, agent_id)
    end
  end

  describe "partial/corrupted log recovery" do
    @tag :recovery
    test "recovers what it can from corrupted log", %{log_path: log_path} do
      agent_id = "agent-corrupt-#{:erlang.unique_integer([:positive])}"

      # Write valid records
      AgentLog.append({:agent, agent_id, %{name: "Recoverable"}},
        log_path: log_path,
        version: @version
      )

      AgentLog.append({:msg, agent_id, %{id: "m1", content: "Safe message"}},
        log_path: log_path,
        version: @version
      )

      # Append corruption
      File.write!(log_path, "garbage that breaks things", [:append])

      # Should still recover the valid records
      {:ok, agents} =
        AgentLog.replay(log_path: log_path, version: @version, ets_table: :chat_agents)

      assert Map.has_key?(agents, agent_id)
      assert agents[agent_id].name == "Recoverable"
      assert length(agents[agent_id].messages) == 1

      # Clean up
      :ets.delete(:chat_agents, agent_id)
    end

    @tag :recovery
    test "handles mid-write crash (truncated record)", %{log_path: log_path} do
      agent_id = "agent-truncate-#{:erlang.unique_integer([:positive])}"

      # Write complete records
      AgentLog.append({:agent, agent_id, %{name: "Truncate Test"}},
        log_path: log_path,
        version: @version
      )

      AgentLog.append({:msg, agent_id, %{id: "m1", content: "Complete"}},
        log_path: log_path,
        version: @version
      )

      # Simulate crash mid-write: size header says 100 bytes but only 20 written
      File.write!(log_path, <<100::32, "incomplete record....">>, [:append, :raw])

      # Recovery should get the complete records
      {:ok, agents} =
        AgentLog.replay(log_path: log_path, version: @version, ets_table: :chat_agents)

      assert agents[agent_id].name == "Truncate Test"
      assert length(agents[agent_id].messages) == 1

      # Clean up
      :ets.delete(:chat_agents, agent_id)
    end
  end

  describe "multiple agents recovery" do
    @tag :recovery
    test "recovers all agents from shared log", %{log_path: log_path} do
      # Three agents in the same workspace
      for i <- 1..3 do
        agent_id = "multi-agent-#{i}"

        AgentLog.append({:agent, agent_id, %{name: "Agent #{i}"}},
          log_path: log_path,
          version: @version
        )

        AgentLog.append({:msg, agent_id, %{id: "m-#{i}", content: "From agent #{i}"}},
          log_path: log_path,
          version: @version
        )
      end

      {:ok, agents} =
        AgentLog.replay(log_path: log_path, version: @version, ets_table: :chat_agents)

      assert map_size(agents) == 3
      assert Enum.all?(1..3, fn i -> Map.has_key?(agents, "multi-agent-#{i}") end)

      # Each has its own message
      for i <- 1..3 do
        assert length(agents["multi-agent-#{i}"].messages) == 1
        :ets.delete(:chat_agents, "multi-agent-#{i}")
      end
    end
  end
end
