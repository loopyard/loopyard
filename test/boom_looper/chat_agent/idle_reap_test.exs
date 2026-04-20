defmodule BoomLooper.ChatAgent.IdleReapTest do
  @moduledoc """
  Surface #20 of plans/agent-sanity.md.

  Long-idle agents hold a Claude CLI subprocess (~200MB RSS) plus the
  SDK Session GenServer indefinitely. With many workspaces and many
  agents per workspace, that RAM never comes back until the user
  manually stops each agent or restarts BoomLooper.

  The reap:
    - On every :idle_check tick (default every 10 min), if the agent
      is :idle, has been inactive longer than :agent_idle_reap_hours
      (default 4h), AND has a captured claude_session_id, we stop the
      CLI subprocess + release the tracked OS pid + null out
      state.session.
    - On the NEXT :send_message, ensure_session_alive detects the
      dead session and spawns a fresh CLI passing
      `resume: <claude_session_id>` — the conversation continues
      seamlessly from the user's perspective.

  Invariants tested:
    1. Idle tick without activity + with session_id + past threshold
       → session nulled, tracked pid released, telemetry fires.
    2. Idle tick WITHOUT claude_session_id (pre-fix agent) → no reap.
    3. Idle tick while :thinking → no reap.
    4. Idle tick before threshold → no reap, just reschedule.
    5. After a reap, next activity spawns a new session via
       ensure_session_alive (covered by session_resume_test.exs #4 —
       "ensure_session_alive passes resume when session_id is set" —
       no need to re-test here).
  """

  use ExUnit.Case, async: false

  alias BoomLooper.ChatAgent
  alias BoomLooper.TestSupport.RecordingBackend

  @moduletag timeout: 10_000

  setup do
    RecordingBackend.reset()

    # Shorten the check interval so the test can observe reaps
    # without waiting 10 min. The reap threshold is checked in
    # seconds so we keep it at default — we'll just backdate
    # last_activity_at.
    Application.put_env(:boom_looper, :agent_idle_check_interval_ms, 100)
    Application.put_env(:boom_looper, :agent_idle_reap_hours, 1)

    on_exit(fn ->
      Application.delete_env(:boom_looper, :agent_idle_check_interval_ms)
      Application.delete_env(:boom_looper, :agent_idle_reap_hours)
    end)

    id = "idle-reap-test-#{:rand.uniform(100_000)}"

    {:ok, _pid} =
      BoomLooper.TestHelpers.start_agent(
        id: id,
        name: "Idle Reap Test",
        working_dir: File.cwd!(),
        started_by: "test",
        backend: RecordingBackend
      )

    on_exit(fn ->
      try do
        ChatAgent.stop_agent(id)
      catch
        :exit, _ -> :ok
      end

      Process.sleep(20)
    end)

    %{id: id}
  end

  defp agent_pid(id) do
    case Registry.lookup(BoomLooper.ChatAgentRegistry, id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp attach_telemetry(parent) do
    handler_id = "idle-reap-test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:boom_looper, :agent, :idle_reaped],
      fn _event, measurements, meta, _cfg ->
        send(parent, {:idle_reaped, measurements, meta})
      end,
      nil
    )

    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  describe "surface #20: idle CLI reap" do
    test "idle + past threshold + has claude_session_id → reap fires", %{id: id} do
      attach_telemetry(self())
      pid = agent_pid(id)

      # Backdate activity past the 1h threshold + install a
      # captured session_id so reap is eligible.
      stale_time = DateTime.add(DateTime.utc_now(), -3700, :second)
      :sys.replace_state(pid, fn s ->
        %{s |
          status: :idle,
          last_activity_at: stale_time,
          claude_session_id: "sess-to-reap-xyz"
        }
      end)

      # Fire :idle_check directly.
      send(pid, :idle_check)

      assert_receive {:idle_reaped, measurements, meta}, 1_000
      assert meta.agent_id == id
      assert measurements.idle_seconds >= 3700

      state = :sys.get_state(pid)
      assert state.session == nil
      assert state.tracked_cli_os_pid == nil
      # Context preserved — the reason a reap is SAFE.
      assert state.claude_session_id == "sess-to-reap-xyz"
    end

    test "no claude_session_id → no reap (pre-fix agent)", %{id: id} do
      attach_telemetry(self())
      pid = agent_pid(id)

      stale_time = DateTime.add(DateTime.utc_now(), -3700, :second)
      original_session = :sys.get_state(pid).session

      :sys.replace_state(pid, fn s ->
        %{s |
          status: :idle,
          last_activity_at: stale_time,
          claude_session_id: nil
        }
      end)

      send(pid, :idle_check)

      # No telemetry event should fire.
      refute_receive {:idle_reaped, _, _}, 300

      state = :sys.get_state(pid)
      # Session untouched.
      assert state.session == original_session
    end

    test "status :thinking → no reap even if idle long", %{id: id} do
      attach_telemetry(self())
      pid = agent_pid(id)

      stale_time = DateTime.add(DateTime.utc_now(), -3700, :second)
      original_session = :sys.get_state(pid).session

      :sys.replace_state(pid, fn s ->
        %{s |
          status: :thinking,
          last_activity_at: stale_time,
          claude_session_id: "sess-xyz"
        }
      end)

      send(pid, :idle_check)

      refute_receive {:idle_reaped, _, _}, 300

      state = :sys.get_state(pid)
      assert state.session == original_session
      assert state.status == :thinking
    end

    test "idle but not yet past threshold → no reap, tick reschedules", %{id: id} do
      attach_telemetry(self())
      pid = agent_pid(id)

      # 5 min idle is way under the 1h (test-configured) threshold.
      recent = DateTime.add(DateTime.utc_now(), -300, :second)
      original_session = :sys.get_state(pid).session

      :sys.replace_state(pid, fn s ->
        %{s |
          status: :idle,
          last_activity_at: recent,
          claude_session_id: "sess-fresh"
        }
      end)

      send(pid, :idle_check)

      refute_receive {:idle_reaped, _, _}, 300

      state = :sys.get_state(pid)
      assert state.session == original_session
      # Timer rescheduled.
      assert is_reference(state.idle_check_timer)
    end
  end
end
