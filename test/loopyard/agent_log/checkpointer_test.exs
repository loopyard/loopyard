defmodule Loopyard.AgentLog.CheckpointerTest do
  use ExUnit.Case, async: false

  alias Loopyard.AgentLog
  alias Loopyard.AgentLog.Checkpointer

  @version 1

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "checkpointer_test_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    log_path = Path.join(tmp_dir, "agents.log")

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{tmp_dir: tmp_dir, log_path: log_path}
  end

  describe "start_link/1" do
    test "starts and registers without crashing", %{log_path: log_path} do
      workspace_id = "ws-start-#{:erlang.unique_integer([:positive])}"

      {:ok, pid} =
        Checkpointer.start_link(
          workspace_id: workspace_id,
          log_path: log_path,
          version: @version,
          interval_ms: 1_000_000,
          records_threshold: 1_000_000
        )

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "threshold-driven snapshots" do
    test "triggers snapshot once records_since_checkpoint crosses threshold",
         %{log_path: log_path} do
      workspace_id = "ws-thresh-#{:erlang.unique_integer([:positive])}"

      # Seed the log with some history
      AgentLog.append({:agent, "a1", %{name: "A1"}}, log_path: log_path, version: @version)

      for i <- 1..9 do
        AgentLog.append(
          {:msg, "a1", %{id: "m#{i}", content: "msg #{i}"}},
          log_path: log_path,
          version: @version
        )
      end

      # Start checkpointer with low threshold and very long interval
      {:ok, pid} =
        Checkpointer.start_link(
          workspace_id: workspace_id,
          log_path: log_path,
          version: @version,
          interval_ms: 1_000_000,
          records_threshold: 5
        )

      # Notify of writes equal to threshold
      for _ <- 1..5, do: Checkpointer.notify_write(pid)

      # Give the checkpointer a moment to process the cast + snapshot
      result = Checkpointer.force_checkpoint(pid)
      assert {:ok, _} = result

      # .prev should exist after a snapshot ran
      assert File.exists?(log_path <> ".prev")

      GenServer.stop(pid)
    end

    test "no snapshot when notify_write count is below threshold", %{log_path: log_path} do
      workspace_id = "ws-nothresh-#{:erlang.unique_integer([:positive])}"
      AgentLog.append({:agent, "a1", %{name: "A1"}}, log_path: log_path, version: @version)

      {:ok, pid} =
        Checkpointer.start_link(
          workspace_id: workspace_id,
          log_path: log_path,
          version: @version,
          interval_ms: 1_000_000,
          records_threshold: 100
        )

      Checkpointer.notify_write(pid)
      Checkpointer.notify_write(pid)

      state = Checkpointer.status(pid)
      assert state.records_since_checkpoint == 2
      assert state.last_checkpoint_at == nil
      refute File.exists?(log_path <> ".prev")

      GenServer.stop(pid)
    end
  end

  describe "interval-driven snapshots" do
    test "takes a snapshot when the scheduled tick fires", %{log_path: log_path} do
      workspace_id = "ws-int-#{:erlang.unique_integer([:positive])}"
      AgentLog.append({:agent, "a1", %{name: "A1"}}, log_path: log_path, version: @version)

      AgentLog.append({:msg, "a1", %{id: "m1", content: "hi"}},
        log_path: log_path,
        version: @version
      )

      # Small interval so the timer fires inside the test
      {:ok, pid} =
        Checkpointer.start_link(
          workspace_id: workspace_id,
          log_path: log_path,
          version: @version,
          interval_ms: 50,
          records_threshold: 1_000_000
        )

      # Wait enough for at least one tick + snapshot
      Process.sleep(200)

      status = Checkpointer.status(pid)
      assert status.last_checkpoint_at != nil
      assert File.exists?(log_path <> ".prev")

      GenServer.stop(pid)
    end

    test "resets records_since_checkpoint after a snapshot", %{log_path: log_path} do
      workspace_id = "ws-reset-#{:erlang.unique_integer([:positive])}"
      AgentLog.append({:agent, "a1", %{name: "A1"}}, log_path: log_path, version: @version)

      {:ok, pid} =
        Checkpointer.start_link(
          workspace_id: workspace_id,
          log_path: log_path,
          version: @version,
          interval_ms: 1_000_000,
          records_threshold: 5
        )

      for _ <- 1..5, do: Checkpointer.notify_write(pid)

      # Force a checkpoint now and then verify counter resets
      {:ok, _} = Checkpointer.force_checkpoint(pid)

      status = Checkpointer.status(pid)
      assert status.records_since_checkpoint == 0

      GenServer.stop(pid)
    end
  end

  describe "keep-two semantics" do
    test "repeated snapshots keep exactly one .prev (not a growing chain)",
         %{log_path: log_path} do
      workspace_id = "ws-keep2-#{:erlang.unique_integer([:positive])}"
      AgentLog.append({:agent, "a1", %{name: "A1"}}, log_path: log_path, version: @version)

      {:ok, pid} =
        Checkpointer.start_link(
          workspace_id: workspace_id,
          log_path: log_path,
          version: @version,
          interval_ms: 1_000_000,
          records_threshold: 1_000_000
        )

      {:ok, _} = Checkpointer.force_checkpoint(pid)
      first_prev = File.read!(log_path <> ".prev")

      # Add more records between snapshots
      AgentLog.append(
        {:msg, "a1", %{id: "m1", content: "after first"}},
        log_path: log_path,
        version: @version
      )

      {:ok, _} = Checkpointer.force_checkpoint(pid)
      second_prev = File.read!(log_path <> ".prev")

      # No chain of .prev.prev.prev — just a single .prev that's been overwritten
      refute File.exists?(log_path <> ".prev.prev")
      assert second_prev != first_prev

      GenServer.stop(pid)
    end
  end

  describe "telemetry" do
    test "emits [:loopyard, :checkpoint, :written] on successful snapshot",
         %{log_path: log_path} do
      workspace_id = "ws-tel-#{:erlang.unique_integer([:positive])}"
      test_pid = self()
      handler_id = "test-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:loopyard, :checkpoint, :written],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      AgentLog.append({:agent, "a1", %{name: "A1"}}, log_path: log_path, version: @version)

      {:ok, pid} =
        Checkpointer.start_link(
          workspace_id: workspace_id,
          log_path: log_path,
          version: @version,
          interval_ms: 1_000_000,
          records_threshold: 1_000_000
        )

      {:ok, _} = Checkpointer.force_checkpoint(pid)

      assert_receive {:telemetry, [:loopyard, :checkpoint, :written], measurements, metadata},
                     500

      assert is_integer(measurements.before_bytes)
      assert is_integer(measurements.after_bytes)
      assert is_integer(measurements.records)
      assert metadata.workspace_id == workspace_id
      assert metadata.path == log_path

      GenServer.stop(pid)
    end
  end

  describe "status/1" do
    test "exposes fields used by /system/recovery", %{log_path: log_path} do
      workspace_id = "ws-status-#{:erlang.unique_integer([:positive])}"

      {:ok, pid} =
        Checkpointer.start_link(
          workspace_id: workspace_id,
          log_path: log_path,
          version: @version,
          interval_ms: 1_000_000,
          records_threshold: 100
        )

      status = Checkpointer.status(pid)
      assert status.workspace_id == workspace_id
      assert status.log_path == log_path
      assert status.records_since_checkpoint == 0
      assert status.last_checkpoint_at == nil

      GenServer.stop(pid)
    end
  end
end
