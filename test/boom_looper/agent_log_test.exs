defmodule BoomLooper.AgentLogTest do
  use ExUnit.Case, async: true

  alias BoomLooper.AgentLog

  @version 1

  setup do
    # Create a unique temp directory for each test
    tmp_dir = Path.join(System.tmp_dir!(), "agent_log_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    log_path = Path.join(tmp_dir, "agents.log")

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
    end)

    %{tmp_dir: tmp_dir, log_path: log_path}
  end

  describe "versioning" do
    test "append without version raises", %{log_path: log_path} do
      assert_raise KeyError, fn ->
        AgentLog.append({:agent, "a1", %{}}, log_path: log_path)
      end
    end

    test "replay without version raises", %{log_path: log_path} do
      assert_raise KeyError, fn ->
        AgentLog.replay(log_path: log_path)
      end
    end

    test "version mismatch returns error", %{log_path: log_path} do
      # Write with version 1
      AgentLog.append({:agent, "a1", %{name: "Test"}}, log_path: log_path, version: 1)

      # Try to read with version 2
      assert {:error, {:version_mismatch, file: 1, requested: 2}} =
               AgentLog.replay(log_path: log_path, version: 2)
    end

    test "matching version works", %{log_path: log_path} do
      AgentLog.append({:agent, "a1", %{name: "Test"}}, log_path: log_path, version: 1)

      assert {:ok, state} = AgentLog.replay(log_path: log_path, version: 1)
      assert Map.has_key?(state, "a1")
    end

    test "first append writes meta header with version", %{log_path: log_path} do
      AgentLog.append({:agent, "a1", %{name: "Test"}}, log_path: log_path, version: 1)

      {:ok, info} = AgentLog.inspect(log_path: log_path)
      assert info.version == 1
      assert %DateTime{} = info.created_at
    end
  end

  describe "inspect/1" do
    test "returns version and all events", %{log_path: log_path} do
      AgentLog.append({:agent, "a1", %{name: "Agent 1"}}, log_path: log_path, version: 1)
      AgentLog.append({:msg, "a1", %{id: "m1", content: "Hello"}}, log_path: log_path, version: 1)

      {:ok, info} = AgentLog.inspect(log_path: log_path)

      assert info.version == 1
      assert length(info.events) == 2
    end

    test "works on non-existent file", %{log_path: log_path} do
      {:ok, info} = AgentLog.inspect(log_path: log_path)

      assert info.version == nil
      assert info.events == []
    end

    test "reads any version without error", %{log_path: log_path} do
      # Write with version 99
      AgentLog.append({:agent, "a1", %{}}, log_path: log_path, version: 99)

      # inspect doesn't care about version
      {:ok, info} = AgentLog.inspect(log_path: log_path)
      assert info.version == 99
    end
  end

  describe "append/2" do
    test "creates log file and writes event", %{log_path: log_path} do
      event = {:agent, "agent-1", %{name: "Test Agent", status: :idle}}

      AgentLog.append(event, log_path: log_path, version: @version)

      assert File.exists?(log_path)
      assert File.stat!(log_path).size > 0
    end

    test "appends multiple events to same file", %{log_path: log_path} do
      event1 = {:agent, "agent-1", %{name: "Agent 1"}}
      event2 = {:agent, "agent-2", %{name: "Agent 2"}}

      AgentLog.append(event1, log_path: log_path, version: @version)
      size_after_first = File.stat!(log_path).size

      AgentLog.append(event2, log_path: log_path, version: @version)
      size_after_second = File.stat!(log_path).size

      assert size_after_second > size_after_first
    end

    test "creates parent directories if they don't exist", %{tmp_dir: tmp_dir} do
      nested_path = Path.join([tmp_dir, "nested", "dir", "agents.log"])

      event = {:agent, "agent-1", %{name: "Test"}}
      AgentLog.append(event, log_path: nested_path, version: @version)

      assert File.exists?(nested_path)
    end

    test "handles all Elixir types (tuples, atoms, maps, datetimes)", %{log_path: log_path} do
      event =
        {:msg, "agent-1",
         %{
           id: "msg-1",
           role: :assistant,
           content: "Hello world",
           timestamp: ~U[2024-01-15 10:30:00Z],
           metadata: %{tool: "bash", nested: %{deep: true}}
         }}

      AgentLog.append(event, log_path: log_path, version: @version)

      {:ok, events} = AgentLog.read_events(log_path: log_path)
      assert events == [event]
    end
  end

  describe "replay/1" do
    test "returns empty map for non-existent log", %{log_path: log_path} do
      assert {:ok, %{}} = AgentLog.replay(log_path: log_path, version: @version)
    end

    test "replays agent creation", %{log_path: log_path} do
      agent_data = %{name: "Test Agent", workspace_id: "ws-1", status: :idle}
      AgentLog.append({:agent, "agent-1", agent_data}, log_path: log_path, version: @version)

      {:ok, state} = AgentLog.replay(log_path: log_path, version: @version)

      assert Map.has_key?(state, "agent-1")
      assert state["agent-1"].name == "Test Agent"
      assert state["agent-1"].workspace_id == "ws-1"
      assert state["agent-1"].messages == []
    end

    test "replays message append", %{log_path: log_path} do
      AgentLog.append({:agent, "agent-1", %{name: "Test"}}, log_path: log_path, version: @version)

      msg = %{id: "msg-1", role: :user, content: "Hello"}
      AgentLog.append({:msg, "agent-1", msg}, log_path: log_path, version: @version)

      {:ok, state} = AgentLog.replay(log_path: log_path, version: @version)

      assert length(state["agent-1"].messages) == 1
      assert hd(state["agent-1"].messages).content == "Hello"
    end

    test "replays multiple messages in order", %{log_path: log_path} do
      AgentLog.append({:agent, "agent-1", %{name: "Test"}}, log_path: log_path, version: @version)
      AgentLog.append({:msg, "agent-1", %{id: "m1", role: :user, content: "First"}}, log_path: log_path, version: @version)
      AgentLog.append({:msg, "agent-1", %{id: "m2", role: :assistant, content: "Second"}}, log_path: log_path, version: @version)
      AgentLog.append({:msg, "agent-1", %{id: "m3", role: :user, content: "Third"}}, log_path: log_path, version: @version)

      {:ok, state} = AgentLog.replay(log_path: log_path, version: @version)

      messages = state["agent-1"].messages
      assert length(messages) == 3
      assert Enum.map(messages, & &1.content) == ["First", "Second", "Third"]
    end

    test "replays message update", %{log_path: log_path} do
      AgentLog.append({:agent, "agent-1", %{name: "Test"}}, log_path: log_path, version: @version)
      AgentLog.append({:msg, "agent-1", %{id: "m1", role: :build, content: ""}}, log_path: log_path, version: @version)
      AgentLog.append({:msg_update, "agent-1", "m1", %{content: "line 1\n"}}, log_path: log_path, version: @version)
      AgentLog.append({:msg_update, "agent-1", "m1", %{content: "line 1\nline 2\n"}}, log_path: log_path, version: @version)
      AgentLog.append({:msg_update, "agent-1", "m1", %{role: :build_done, content: "final output"}}, log_path: log_path, version: @version)

      {:ok, state} = AgentLog.replay(log_path: log_path, version: @version)

      msg = hd(state["agent-1"].messages)
      assert msg.role == :build_done
      assert msg.content == "final output"
    end

    test "handles multiple agents", %{log_path: log_path} do
      AgentLog.append({:agent, "agent-1", %{name: "Agent 1"}}, log_path: log_path, version: @version)
      AgentLog.append({:agent, "agent-2", %{name: "Agent 2"}}, log_path: log_path, version: @version)
      AgentLog.append({:msg, "agent-1", %{id: "m1", content: "From 1"}}, log_path: log_path, version: @version)
      AgentLog.append({:msg, "agent-2", %{id: "m2", content: "From 2"}}, log_path: log_path, version: @version)

      {:ok, state} = AgentLog.replay(log_path: log_path, version: @version)

      assert Map.keys(state) |> Enum.sort() == ["agent-1", "agent-2"]
      assert hd(state["agent-1"].messages).content == "From 1"
      assert hd(state["agent-2"].messages).content == "From 2"
    end

    test "agent update preserves existing messages", %{log_path: log_path} do
      AgentLog.append({:agent, "agent-1", %{name: "Original", status: :idle}}, log_path: log_path, version: @version)
      AgentLog.append({:msg, "agent-1", %{id: "m1", content: "Message"}}, log_path: log_path, version: @version)
      AgentLog.append({:agent, "agent-1", %{name: "Updated", status: :thinking}}, log_path: log_path, version: @version)

      {:ok, state} = AgentLog.replay(log_path: log_path, version: @version)

      assert state["agent-1"].name == "Updated"
      assert state["agent-1"].status == :thinking
      assert length(state["agent-1"].messages) == 1
    end

    test "message to non-existent agent creates agent entry", %{log_path: log_path} do
      # No :agent event, just a message
      AgentLog.append({:msg, "agent-1", %{id: "m1", content: "Orphan message"}}, log_path: log_path, version: @version)

      {:ok, state} = AgentLog.replay(log_path: log_path, version: @version)

      assert Map.has_key?(state, "agent-1")
      assert length(state["agent-1"].messages) == 1
    end

    test "msg_update to non-existent agent is ignored", %{log_path: log_path} do
      AgentLog.append({:msg_update, "agent-1", "m1", %{content: "Updated"}}, log_path: log_path, version: @version)

      {:ok, state} = AgentLog.replay(log_path: log_path, version: @version)

      assert state == %{}
    end

    test "msg_update to non-existent message is no-op", %{log_path: log_path} do
      AgentLog.append({:agent, "agent-1", %{name: "Test"}}, log_path: log_path, version: @version)
      AgentLog.append({:msg, "agent-1", %{id: "m1", content: "Original"}}, log_path: log_path, version: @version)
      AgentLog.append({:msg_update, "agent-1", "wrong-id", %{content: "Updated"}}, log_path: log_path, version: @version)

      {:ok, state} = AgentLog.replay(log_path: log_path, version: @version)

      assert hd(state["agent-1"].messages).content == "Original"
    end
  end

  describe "replay/1 with ETS" do
    setup %{log_path: log_path} do
      table = :ets.new(:test_agents, [:set, :public])

      on_exit(fn ->
        try do
          :ets.delete(table)
        rescue
          ArgumentError -> :ok
        end
      end)

      %{log_path: log_path, ets_table: table}
    end

    test "populates ETS table on replay", %{log_path: log_path, ets_table: table} do
      AgentLog.append({:agent, "agent-1", %{name: "Test Agent"}}, log_path: log_path, version: @version)
      AgentLog.append({:msg, "agent-1", %{id: "m1", content: "Hello"}}, log_path: log_path, version: @version)

      {:ok, _state} = AgentLog.replay(log_path: log_path, version: @version, ets_table: table)

      assert [{"agent-1", data}] = :ets.lookup(table, "agent-1")
      assert data.name == "Test Agent"
      assert length(data.messages) == 1
    end

    test "populates multiple agents in ETS", %{log_path: log_path, ets_table: table} do
      AgentLog.append({:agent, "agent-1", %{name: "Agent 1"}}, log_path: log_path, version: @version)
      AgentLog.append({:agent, "agent-2", %{name: "Agent 2"}}, log_path: log_path, version: @version)

      {:ok, _state} = AgentLog.replay(log_path: log_path, version: @version, ets_table: table)

      assert :ets.info(table, :size) == 2
    end

    test "version mismatch doesn't populate ETS", %{log_path: log_path, ets_table: table} do
      AgentLog.append({:agent, "agent-1", %{name: "Test"}}, log_path: log_path, version: 1)

      {:error, {:version_mismatch, _}} = AgentLog.replay(log_path: log_path, version: 2, ets_table: table)

      assert :ets.info(table, :size) == 0
    end
  end

  describe "partial/corrupted records" do
    test "handles truncated size header", %{log_path: log_path} do
      # Write a valid record first
      AgentLog.append({:agent, "agent-1", %{name: "Valid"}}, log_path: log_path, version: @version)

      # Append partial size header (only 2 bytes instead of 4)
      File.write!(log_path, <<0, 1>>, [:append, :raw])

      {:ok, state} = AgentLog.replay(log_path: log_path, version: @version)

      # Should recover the valid record
      assert Map.has_key?(state, "agent-1")
    end

    test "handles truncated data", %{log_path: log_path} do
      # Write a valid record first
      AgentLog.append({:agent, "agent-1", %{name: "Valid"}}, log_path: log_path, version: @version)

      # Append size header claiming 100 bytes, but only 10 bytes of data
      File.write!(log_path, <<100::32, "short data">>, [:append, :raw])

      {:ok, state} = AgentLog.replay(log_path: log_path, version: @version)

      # Should recover the valid record
      assert Map.has_key?(state, "agent-1")
    end

    test "handles corrupted ETF data", %{log_path: log_path} do
      # Write a valid record first
      AgentLog.append({:agent, "agent-1", %{name: "Valid"}}, log_path: log_path, version: @version)

      # Append valid-looking record with garbage ETF data
      garbage = "this is not valid ETF"
      File.write!(log_path, <<byte_size(garbage)::32, garbage::binary>>, [:append, :raw])

      {:ok, state} = AgentLog.replay(log_path: log_path, version: @version)

      # Should recover the valid record, skip corrupted one
      assert Map.has_key?(state, "agent-1")
      assert map_size(state) == 1
    end

    test "recovers all valid records before corruption", %{log_path: log_path} do
      AgentLog.append({:agent, "agent-1", %{name: "First"}}, log_path: log_path, version: @version)
      AgentLog.append({:agent, "agent-2", %{name: "Second"}}, log_path: log_path, version: @version)
      AgentLog.append({:agent, "agent-3", %{name: "Third"}}, log_path: log_path, version: @version)

      # Corrupt the file by truncating mid-record
      content = File.read!(log_path)
      truncated = binary_part(content, 0, byte_size(content) - 5)
      File.write!(log_path, truncated)

      {:ok, state} = AgentLog.replay(log_path: log_path, version: @version)

      # Should recover at least the first two records
      assert Map.has_key?(state, "agent-1")
      assert Map.has_key?(state, "agent-2")
    end
  end

  describe "read_events/1" do
    test "returns empty list for non-existent log", %{log_path: log_path} do
      assert {:ok, []} = AgentLog.read_events(log_path: log_path)
    end

    test "returns all events in order (excludes meta)", %{log_path: log_path} do
      events = [
        {:agent, "a1", %{name: "Agent 1"}},
        {:msg, "a1", %{id: "m1", content: "Hello"}},
        {:msg_update, "a1", "m1", %{content: "Updated"}}
      ]

      for event <- events do
        AgentLog.append(event, log_path: log_path, version: @version)
      end

      {:ok, read} = AgentLog.read_events(log_path: log_path)
      assert read == events
    end
  end

  describe "concurrent writes" do
    test "multiple processes can append safely", %{log_path: log_path} do
      # Write initial meta header
      AgentLog.append({:agent, "init", %{}}, log_path: log_path, version: @version)

      # Spawn 10 processes, each writing 10 events
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            for j <- 1..10 do
              event = {:msg, "agent-#{i}", %{id: "m-#{i}-#{j}", content: "Message #{j}"}}
              AgentLog.append(event, log_path: log_path, version: @version)
            end
          end)
        end

      Task.await_many(tasks, 5000)

      {:ok, events} = AgentLog.read_events(log_path: log_path)

      # All 101 events should be present (1 init + 100 messages)
      assert length(events) == 101
    end

    test "concurrent writes followed by replay produces correct state", %{log_path: log_path} do
      # Create agents first
      for i <- 1..5 do
        AgentLog.append({:agent, "agent-#{i}", %{name: "Agent #{i}"}}, log_path: log_path, version: @version)
      end

      # Concurrent message writes
      tasks =
        for i <- 1..5 do
          Task.async(fn ->
            for j <- 1..5 do
              event = {:msg, "agent-#{i}", %{id: "m-#{i}-#{j}", content: "Msg #{j}"}}
              AgentLog.append(event, log_path: log_path, version: @version)
            end
          end)
        end

      Task.await_many(tasks, 5000)

      {:ok, state} = AgentLog.replay(log_path: log_path, version: @version)

      # Each agent should have 5 messages
      for i <- 1..5 do
        assert length(state["agent-#{i}"].messages) == 5
      end
    end
  end
end
