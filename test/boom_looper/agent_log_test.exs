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

      {:ok, info} = AgentLog.peek(log_path: log_path)
      assert info.version == 1
      assert %DateTime{} = info.created_at
    end
  end

  describe "peek/1" do
    test "returns version and all events", %{log_path: log_path} do
      AgentLog.append({:agent, "a1", %{name: "Agent 1"}}, log_path: log_path, version: 1)
      AgentLog.append({:msg, "a1", %{id: "m1", content: "Hello"}}, log_path: log_path, version: 1)

      {:ok, info} = AgentLog.peek(log_path: log_path)

      assert info.version == 1
      assert length(info.events) == 2
    end

    test "works on non-existent file", %{log_path: log_path} do
      {:ok, info} = AgentLog.peek(log_path: log_path)

      assert info.version == nil
      assert info.events == []
    end

    test "reads any version without error", %{log_path: log_path} do
      # Write with version 99
      AgentLog.append({:agent, "a1", %{}}, log_path: log_path, version: 99)

      # peek doesn't care about version
      {:ok, info} = AgentLog.peek(log_path: log_path)
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

  describe "migrate/1" do
    # Migration uses atomic file rename for crash safety:
    # 1. Read all events from original file (any version via inspect/1)
    # 2. Transform each event with user-provided function
    # 3. Write transformed events to temp file (.migrating suffix)
    # 4. Atomic rename temp -> original
    #
    # If crash occurs during steps 1-3, original file is untouched.
    # Step 4 is atomic on POSIX - either old or new file, never partial.

    test "migrates from v1 to v2 with transformer", %{log_path: log_path} do
      # Write v1 data
      AgentLog.append({:agent, "a1", %{name: "Test"}}, log_path: log_path, version: 1)
      AgentLog.append({:msg, "a1", %{id: "m1", content: "Hello"}}, log_path: log_path, version: 1)

      # Migrate: rename :msg to :message
      transformer = fn
        {:msg, agent_id, data} -> {:message, agent_id, data}
        other -> other
      end

      assert :ok = AgentLog.migrate(
        log_path: log_path,
        from: 1,
        to: 2,
        transformer: transformer
      )

      # File is now v2
      {:ok, info} = AgentLog.peek(log_path: log_path)
      assert info.version == 2

      # Events were transformed
      assert Enum.any?(info.events, fn
        {:message, "a1", _} -> true
        _ -> false
      end)

      # Old :msg format is gone
      refute Enum.any?(info.events, fn
        {:msg, _, _} -> true
        _ -> false
      end)
    end

    test "returns error when file doesn't exist", %{log_path: log_path} do
      result = AgentLog.migrate(
        log_path: log_path,
        from: 1,
        to: 2,
        transformer: &Function.identity/1
      )

      assert {:error, :file_not_found} = result
    end

    test "returns error when file version doesn't match expected", %{log_path: log_path} do
      # Write v1 data
      AgentLog.append({:agent, "a1", %{name: "Test"}}, log_path: log_path, version: 1)

      # Try to migrate from v2 (but file is v1)
      result = AgentLog.migrate(
        log_path: log_path,
        from: 2,
        to: 3,
        transformer: &Function.identity/1
      )

      assert {:error, {:unexpected_version, got: 1, expected: 2}} = result

      # Original file unchanged
      {:ok, info} = AgentLog.peek(log_path: log_path)
      assert info.version == 1
    end

    test "identity transformer just bumps version", %{log_path: log_path} do
      # Write v1 data with multiple events
      AgentLog.append({:agent, "a1", %{name: "Agent 1"}}, log_path: log_path, version: 1)
      AgentLog.append({:agent, "a2", %{name: "Agent 2"}}, log_path: log_path, version: 1)
      AgentLog.append({:msg, "a1", %{id: "m1", content: "Hello"}}, log_path: log_path, version: 1)

      # Migrate with identity (no transformation, just version bump)
      assert :ok = AgentLog.migrate(
        log_path: log_path,
        from: 1,
        to: 2,
        transformer: &Function.identity/1
      )

      # Version bumped
      {:ok, info} = AgentLog.peek(log_path: log_path)
      assert info.version == 2

      # All events preserved
      assert length(info.events) == 3
    end

    test "cleans up temp file on success", %{log_path: log_path} do
      AgentLog.append({:agent, "a1", %{name: "Test"}}, log_path: log_path, version: 1)

      assert :ok = AgentLog.migrate(
        log_path: log_path,
        from: 1,
        to: 2,
        transformer: &Function.identity/1
      )

      # No .migrating file left behind
      refute File.exists?(log_path <> ".migrating")
    end

    test "removes stale temp file from previous failed migration", %{log_path: log_path} do
      AgentLog.append({:agent, "a1", %{name: "Test"}}, log_path: log_path, version: 1)

      # Create stale temp file (simulates previous crash)
      File.write!(log_path <> ".migrating", "stale data from crashed migration")

      assert :ok = AgentLog.migrate(
        log_path: log_path,
        from: 1,
        to: 2,
        transformer: &Function.identity/1
      )

      # Migration succeeded, original file is v2
      {:ok, info} = AgentLog.peek(log_path: log_path)
      assert info.version == 2
    end

    test "all events pass through transformer", %{log_path: log_path} do
      # Write various event types
      AgentLog.append({:agent, "a1", %{name: "Test", count: 0}}, log_path: log_path, version: 1)
      AgentLog.append({:msg, "a1", %{id: "m1", count: 0}}, log_path: log_path, version: 1)
      AgentLog.append({:msg_update, "a1", "m1", %{count: 0}}, log_path: log_path, version: 1)

      # Transformer increments count in all events
      transformer = fn
        {:agent, id, data} -> {:agent, id, Map.update!(data, :count, &(&1 + 1))}
        {:msg, id, data} -> {:msg, id, Map.update!(data, :count, &(&1 + 1))}
        {:msg_update, id, msg_id, data} -> {:msg_update, id, msg_id, Map.update!(data, :count, &(&1 + 1))}
        other -> other
      end

      assert :ok = AgentLog.migrate(
        log_path: log_path,
        from: 1,
        to: 2,
        transformer: transformer
      )

      {:ok, info} = AgentLog.peek(log_path: log_path)

      # All events have count: 1 (incremented from 0)
      for event <- info.events do
        case event do
          {:agent, _, %{count: count}} -> assert count == 1
          {:msg, _, %{count: count}} -> assert count == 1
          {:msg_update, _, _, %{count: count}} -> assert count == 1
        end
      end
    end

    test "replayed state identical after identity migration", %{log_path: log_path} do
      # Build up realistic state
      AgentLog.append({:agent, "a1", %{name: "Agent 1", status: :idle}}, log_path: log_path, version: 1)
      AgentLog.append({:msg, "a1", %{id: "m1", role: :user, content: "Hello"}}, log_path: log_path, version: 1)
      AgentLog.append({:msg, "a1", %{id: "m2", role: :assistant, content: "Hi there"}}, log_path: log_path, version: 1)
      AgentLog.append({:agent, "a2", %{name: "Agent 2"}}, log_path: log_path, version: 1)

      # Capture state before migration
      {:ok, state_before} = AgentLog.replay(log_path: log_path, version: 1)

      # Migrate with identity
      assert :ok = AgentLog.migrate(
        log_path: log_path,
        from: 1,
        to: 2,
        transformer: &Function.identity/1
      )

      # State after should be identical
      {:ok, state_after} = AgentLog.replay(log_path: log_path, version: 2)

      assert state_before == state_after
    end

    test "created_at reflects when file was written, not original creation", %{log_path: log_path} do
      AgentLog.append({:agent, "a1", %{name: "Test"}}, log_path: log_path, version: 1)

      {:ok, info_before} = AgentLog.peek(log_path: log_path)

      # Small delay to ensure timestamps would differ
      Process.sleep(10)

      assert :ok = AgentLog.migrate(
        log_path: log_path,
        from: 1,
        to: 2,
        transformer: &Function.identity/1
      )

      {:ok, info_after} = AgentLog.peek(log_path: log_path)

      # created_at is NOT preserved - it reflects when the v2 file was created.
      # This is intentional. If you need to track original creation, store it
      # in the events themselves. The meta.created_at is for the current file.
      assert %DateTime{} = info_after.created_at
      assert DateTime.compare(info_after.created_at, info_before.created_at) == :gt
    end

    test "multi-step migration chain v1→v2→v3", %{log_path: log_path} do
      # Start with v1 data
      AgentLog.append({:agent, "a1", %{name: "Test", v1_field: true}}, log_path: log_path, version: 1)
      AgentLog.append({:msg, "a1", %{id: "m1", content: "Hello"}}, log_path: log_path, version: 1)

      # v1→v2: add migrated_at field
      v1_to_v2 = fn
        {:agent, id, data} -> {:agent, id, Map.put(data, :migrated_v2, true)}
        other -> other
      end

      assert :ok = AgentLog.migrate(
        log_path: log_path,
        from: 1,
        to: 2,
        transformer: v1_to_v2
      )

      {:ok, info_v2} = AgentLog.peek(log_path: log_path)
      assert info_v2.version == 2

      # v2→v3: rename :msg to :message
      v2_to_v3 = fn
        {:msg, id, data} -> {:message, id, data}
        other -> other
      end

      assert :ok = AgentLog.migrate(
        log_path: log_path,
        from: 2,
        to: 3,
        transformer: v2_to_v3
      )

      {:ok, info_v3} = AgentLog.peek(log_path: log_path)
      assert info_v3.version == 3

      # Both transformations applied
      assert Enum.any?(info_v3.events, fn
        {:agent, _, %{migrated_v2: true}} -> true
        _ -> false
      end)

      assert Enum.any?(info_v3.events, fn
        {:message, _, _} -> true
        _ -> false
      end)

      # Old formats gone
      refute Enum.any?(info_v3.events, fn
        {:msg, _, _} -> true
        _ -> false
      end)
    end
  end

  describe "compact/1" do
    test "rewrites the log as a minimal snapshot and shrinks the file",
         %{log_path: log_path} do
      # Write many record types that collapse to a small final state:
      # one agent with ten messages, each updated three times (the
      # exact streaming pattern that bloats the file for long chats),
      # plus churn on a second agent that ultimately gets removed.
      AgentLog.append({:agent, "a1", %{name: "A1"}}, log_path: log_path, version: @version)

      for i <- 1..10 do
        AgentLog.append(
          {:msg, "a1", %{id: "m#{i}", role: :user, content: "msg #{i}"}},
          log_path: log_path,
          version: @version
        )

        for _ <- 1..3 do
          AgentLog.append(
            {:msg_update, "a1", "m#{i}", %{content: "msg #{i} updated"}},
            log_path: log_path,
            version: @version
          )
        end
      end

      AgentLog.append({:agent, "a2", %{name: "A2"}}, log_path: log_path, version: @version)

      AgentLog.append(
        {:msg, "a2", %{id: "m99", role: :user, content: "scratch"}},
        log_path: log_path,
        version: @version
      )

      AgentLog.append({:agent_removed, "a2"}, log_path: log_path, version: @version)

      {:ok, state_before} = AgentLog.replay(log_path: log_path, version: @version)

      {:ok, %{before: before_bytes, after: after_bytes, agents: agents, messages: messages}} =
        AgentLog.compact(log_path: log_path, version: @version)

      assert after_bytes < before_bytes, "compaction should shrink the file"
      assert agents == 1
      assert messages == 10

      # Replaying the compacted log yields the same in-memory state.
      {:ok, state_after} = AgentLog.replay(log_path: log_path, version: @version)
      assert state_before == state_after
    end

    test "no-op when the file doesn't exist", %{log_path: log_path} do
      refute File.exists?(log_path)

      assert {:ok, %{before: 0, after: 0, agents: 0, messages: 0}} =
               AgentLog.compact(log_path: log_path, version: @version)
    end

    test "atomic — temp file is gone after success", %{log_path: log_path} do
      AgentLog.append({:agent, "a1", %{name: "A"}}, log_path: log_path, version: @version)
      {:ok, _} = AgentLog.compact(log_path: log_path, version: @version)

      refute File.exists?(log_path <> ".compacting")
    end
  end

  describe "maybe_compact/1" do
    test "skips when the file is under the threshold",
         %{log_path: log_path} do
      AgentLog.append({:agent, "a1", %{name: "A"}}, log_path: log_path, version: @version)
      before = File.stat!(log_path).size

      assert {:ok, :skipped} =
               AgentLog.maybe_compact(
                 log_path: log_path,
                 version: @version,
                 threshold_bytes: 1_000_000
               )

      assert File.stat!(log_path).size == before
    end

    test "compacts when over the threshold",
         %{log_path: log_path} do
      for _ <- 1..100 do
        AgentLog.append(
          {:msg_update, "a1", "m1", %{content: String.duplicate("x", 200)}},
          log_path: log_path,
          version: @version
        )
      end

      AgentLog.append({:agent, "a1", %{name: "A"}}, log_path: log_path, version: @version)

      assert {:ok, %{before: b, after: a}} =
               AgentLog.maybe_compact(
                 log_path: log_path,
                 version: @version,
                 threshold_bytes: 100
               )

      assert a < b
    end

    test "no-op when the file doesn't exist",
         %{log_path: log_path} do
      refute File.exists?(log_path)

      assert {:ok, :skipped} =
               AgentLog.maybe_compact(log_path: log_path, version: @version)
    end
  end

  describe "compact_keep_previous/1" do
    test "moves current log to .prev before compacting", %{log_path: log_path} do
      AgentLog.append({:agent, "a1", %{name: "A1"}}, log_path: log_path, version: @version)

      for i <- 1..5 do
        AgentLog.append(
          {:msg, "a1", %{id: "m#{i}", content: "msg #{i}"}},
          log_path: log_path,
          version: @version
        )
      end

      original = File.read!(log_path)

      assert {:ok, stats} =
               AgentLog.compact_keep_previous(log_path: log_path, version: @version)

      # .prev contains the pre-compaction file
      prev_path = log_path <> ".prev"
      assert File.exists?(prev_path)
      assert File.read!(prev_path) == original

      # current is the compacted snapshot
      assert File.exists?(log_path)
      assert stats.agents == 1
      assert stats.messages == 5
    end

    test "second compaction overwrites the older .prev with the most recent primary",
         %{log_path: log_path} do
      # First snapshot round
      AgentLog.append({:agent, "a1", %{name: "A1"}}, log_path: log_path, version: @version)
      {:ok, _} = AgentLog.compact_keep_previous(log_path: log_path, version: @version)

      first_prev = File.read!(log_path <> ".prev")

      # Second round with more data
      AgentLog.append(
        {:msg, "a1", %{id: "m1", content: "hi"}},
        log_path: log_path,
        version: @version
      )

      before_second = File.read!(log_path)

      {:ok, _} = AgentLog.compact_keep_previous(log_path: log_path, version: @version)

      # .prev now holds the previous (middle) state, not the very first
      second_prev = File.read!(log_path <> ".prev")
      assert second_prev == before_second
      refute second_prev == first_prev
    end

    test "no-op when the file doesn't exist", %{log_path: log_path} do
      refute File.exists?(log_path)

      assert {:ok, %{before: 0, after: 0, agents: 0, messages: 0}} =
               AgentLog.compact_keep_previous(log_path: log_path, version: @version)

      refute File.exists?(log_path <> ".prev")
    end

    test "replay after compaction yields the same state as before",
         %{log_path: log_path} do
      AgentLog.append({:agent, "a1", %{name: "A1"}}, log_path: log_path, version: @version)

      for i <- 1..10 do
        AgentLog.append(
          {:msg, "a1", %{id: "m#{i}", role: :user, content: "msg #{i}"}},
          log_path: log_path,
          version: @version
        )

        AgentLog.append(
          {:msg_update, "a1", "m#{i}", %{content: "msg #{i} final"}},
          log_path: log_path,
          version: @version
        )
      end

      {:ok, state_before} = AgentLog.replay(log_path: log_path, version: @version)

      assert {:ok, _stats} =
               AgentLog.compact_keep_previous(log_path: log_path, version: @version)

      {:ok, state_after} = AgentLog.replay(log_path: log_path, version: @version)
      assert state_before == state_after
    end

    test "leaves the compacting temp file absent on success", %{log_path: log_path} do
      AgentLog.append({:agent, "a1", %{name: "A1"}}, log_path: log_path, version: @version)
      {:ok, _} = AgentLog.compact_keep_previous(log_path: log_path, version: @version)

      refute File.exists?(log_path <> ".compacting")
    end
  end

  describe "replay_with_fallback/1" do
    test "loads primary when primary is valid", %{log_path: log_path} do
      AgentLog.append({:agent, "a1", %{name: "A1"}}, log_path: log_path, version: @version)

      assert {:ok, state, :primary} =
               AgentLog.replay_with_fallback(log_path: log_path, version: @version)

      assert Map.has_key?(state, "a1")
    end

    test "returns empty state when neither primary nor .prev exist", %{log_path: log_path} do
      assert {:ok, state, :primary} =
               AgentLog.replay_with_fallback(log_path: log_path, version: @version)

      assert state == %{}
    end

    test "falls back to .prev when primary is corrupt (garbage bytes)",
         %{log_path: log_path} do
      # Write a valid .prev with an agent
      prev_path = log_path <> ".prev"
      AgentLog.append({:agent, "a1", %{name: "A1"}}, log_path: prev_path, version: @version)

      # Write a corrupt primary file (garbage that won't yield a valid meta header)
      File.write!(log_path, "this is complete garbage, not a valid log file at all")

      assert {:ok, state, :previous} =
               AgentLog.replay_with_fallback(log_path: log_path, version: @version)

      assert Map.has_key?(state, "a1")
    end

    test "falls back to .prev when primary has version mismatch",
         %{log_path: log_path} do
      # Primary at v1, .prev at v1, but we ask for v2 — primary mismatch
      AgentLog.append({:agent, "a_primary", %{name: "primary"}}, log_path: log_path, version: 1)

      prev_path = log_path <> ".prev"
      AgentLog.append({:agent, "a_prev", %{name: "prev"}}, log_path: prev_path, version: 1)

      # Asking for v2 — both mismatched. Primary mismatch first; .prev mismatch → error
      # But both mismatch so we should surface the mismatch error, not crash.
      assert {:error, _} =
               AgentLog.replay_with_fallback(log_path: log_path, version: 2)
    end

    test "uses primary when .prev exists but primary is valid", %{log_path: log_path} do
      # Both exist — primary must win
      AgentLog.append(
        {:agent, "from_primary", %{name: "primary"}},
        log_path: log_path,
        version: @version
      )

      prev_path = log_path <> ".prev"

      AgentLog.append(
        {:agent, "from_prev", %{name: "prev"}},
        log_path: prev_path,
        version: @version
      )

      assert {:ok, state, :primary} =
               AgentLog.replay_with_fallback(log_path: log_path, version: @version)

      assert Map.has_key?(state, "from_primary")
      refute Map.has_key?(state, "from_prev")
    end

    test "treats zero-length primary as missing, not corruption",
         %{log_path: log_path} do
      # Primary exists but is empty (not just missing)
      File.write!(log_path, "")

      # Empty primary is not "corruption worth falling back from". Treat as
      # "no events yet" → empty state, :primary marker. This mirrors the
      # behaviour of replay/1 on a missing file.
      assert {:ok, state, :primary} =
               AgentLog.replay_with_fallback(log_path: log_path, version: @version)

      assert state == %{}
    end

    test "populates ETS when primary loads", %{log_path: log_path} do
      table = :ets.new(:fallback_test_1, [:set, :public])

      try do
        AgentLog.append(
          {:agent, "a1", %{name: "A1"}},
          log_path: log_path,
          version: @version
        )

        assert {:ok, _state, :primary} =
                 AgentLog.replay_with_fallback(
                   log_path: log_path,
                   version: @version,
                   ets_table: table
                 )

        assert [{"a1", _}] = :ets.lookup(table, "a1")
      after
        :ets.delete(table)
      end
    end

    test "populates ETS when .prev is used", %{log_path: log_path} do
      table = :ets.new(:fallback_test_2, [:set, :public])

      try do
        prev_path = log_path <> ".prev"
        AgentLog.append({:agent, "a1", %{name: "A1"}}, log_path: prev_path, version: @version)

        File.write!(log_path, "garbage")

        assert {:ok, _state, :previous} =
                 AgentLog.replay_with_fallback(
                   log_path: log_path,
                   version: @version,
                   ets_table: table
                 )

        assert [{"a1", _}] = :ets.lookup(table, "a1")
      after
        :ets.delete(table)
      end
    end
  end

  describe "keep-two-snapshots integration with corruption" do
    # 50 records × two compactions × replay × file-corruption step —
    # under suite I/O contention this legitimately takes several
    # seconds. The production replay path has no such budget; this
    # is test-only work.
    @tag timeout: 15_000
    test "many records → compact_keep_previous → corrupt primary → replay_with_fallback recovers",
         %{log_path: log_path} do
      # Build a realistic log
      AgentLog.append({:agent, "a1", %{name: "Agent 1"}}, log_path: log_path, version: @version)
      AgentLog.append({:agent, "a2", %{name: "Agent 2"}}, log_path: log_path, version: @version)

      for i <- 1..50 do
        AgentLog.append(
          {:msg, "a1", %{id: "m1_#{i}", content: "msg #{i}"}},
          log_path: log_path,
          version: @version
        )

        AgentLog.append(
          {:msg, "a2", %{id: "m2_#{i}", content: "msg #{i}"}},
          log_path: log_path,
          version: @version
        )
      end

      # Take a snapshot (keep-previous semantics)
      {:ok, _} = AgentLog.compact_keep_previous(log_path: log_path, version: @version)
      assert File.exists?(log_path <> ".prev")

      # Now simulate the primary getting corrupted after compaction
      {:ok, expected_state} = AgentLog.replay(log_path: log_path, version: @version)

      # Corrupt it
      File.write!(log_path, "totally garbage bytes that fail to parse")

      # Fallback kicks in and we recover .prev's state (which is the original
      # pre-compaction log, replaying to the same state).
      assert {:ok, recovered, :previous} =
               AgentLog.replay_with_fallback(log_path: log_path, version: @version)

      assert recovered == expected_state
    end
  end
end
