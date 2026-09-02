defmodule Loopyard.ChatAgent.RestartStateTest do
  @moduledoc """
  Surfaces #2 + #4 of plans/agent-sanity.md.

  Two related invariants about state that rides across CLI / server
  restart cycles:

  **#2 — token/cost/model durability.** `total_input_tokens`,
  `total_output_tokens`, `total_cache_read_tokens`, `total_cost_usd`,
  and `model` accumulate turn-by-turn and MUST survive a Loopyard
  server restart. `summary/1` already exposes them; this test locks in
  that `init_resume` rebuilds the struct with those fields preserved.

  **#4 — `active_tool` cannot stick after a restart/reset.** If the CLI
  dies with a tool mid-flight, the UI spinner would pin forever without
  an explicit clear. Every "reset to idle / backoff / crashed /
  rate_limited / auth_expired" path now clears `active_tool`. This
  test pins down each reset path against re-introduction.
  """

  use Loopyard.AgentCase

  alias Loopyard.ChatAgent
  alias Loopyard.Agent.Event
  alias Loopyard.TestSupport.RecordingBackend

  @moduletag timeout: 10_000

  setup do
    RecordingBackend.reset()
    Application.put_env(:loopyard, :crash_backoff_base_ms, 0)
    on_exit(fn -> Application.delete_env(:loopyard, :crash_backoff_base_ms) end)

    id = "restart-state-test-#{:rand.uniform(100_000)}"

    {:ok, _pid} =
      Loopyard.TestHelpers.start_agent(
        id: id,
        name: "Restart State Test",
        started_by: "test",
        backend: RecordingBackend
      )

    ChatAgent.subscribe()
    ChatAgent.subscribe(id)

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
    case Registry.lookup(Loopyard.ChatAgentRegistry, id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  describe "surface #2: token/cost/model durability across init_resume" do
    test "summary preserves accumulated tokens, cost, model across restart", %{id: id} do
      pid = agent_pid(id)

      # Install a known stream_ref so ref-tagged events match the
      # agent's current stream (agent-sanity #16).
      ref = make_ref()
      :sys.replace_state(pid, fn s -> %{s | stream_ref: ref} end)

      # Simulate several turns via SessionResult events. Each bumps the
      # accumulators.
      for {in_tok, out_tok, cache, cost} <- [
            {100, 50, 0, 0.01},
            {200, 80, 500, 0.02},
            {50, 20, 100, 0.005}
          ] do
        send(
          pid,
          {:stream_event, id, ref,
           %Event.SessionResult{
             model: "claude-opus-4-7",
             input_tokens: in_tok,
             output_tokens: out_tok,
             cache_read_tokens: cache,
             cost_usd: cost,
             duration_ms: 1_000,
             num_turns: 1
           }}
        )
      end

      # Let the handlers flush.
      _ = :sys.get_state(pid)

      live_state = :sys.get_state(pid)
      expected_in = 350
      expected_out = 150
      expected_cache = 600
      expected_cost = 0.035

      assert live_state.total_input_tokens == expected_in
      assert live_state.total_output_tokens == expected_out
      assert live_state.total_cache_read_tokens == expected_cache
      assert_in_delta live_state.total_cost_usd, expected_cost, 0.0001
      assert live_state.model == "claude-opus-4-7"

      # Stop + resume-spawn to simulate a Loopyard server restart.
      ChatAgent.stop_agent(id)
      Process.sleep(30)
      refute agent_pid(id) |> is_pid()

      {:ok, _} =
        Loopyard.TestHelpers.start_agent(
          id: id,
          name: "Restart State Test",
          started_by: "test",
          backend: RecordingBackend,
          resume: true
        )

      new_pid = agent_pid(id)
      new_state = :sys.get_state(new_pid)

      # The whole point of init_resume: every durable field survives.
      assert new_state.total_input_tokens == expected_in
      assert new_state.total_output_tokens == expected_out
      assert new_state.total_cache_read_tokens == expected_cache
      assert_in_delta new_state.total_cost_usd, expected_cost, 0.0001
      assert new_state.model == "claude-opus-4-7"
    end
  end

  describe "surface #4: active_tool cleared on every reset path" do
    # Stall-watchdog semantics: a timeout with a TOOL IN FLIGHT is a busy
    # harness (long command, quiet stream) — it must NOT reboot or clear
    # anything. The reboot-and-clear contract applies to the wedge case:
    # silent past the window with no tool open.
    test "stream_timeout with a tool in flight leaves the turn alone", %{id: id} do
      pid = agent_pid(id)

      :sys.replace_state(pid, fn s ->
        %{s | status: :thinking, active_tool: "docker_compose", stream_ref: make_ref()}
        |> Map.put(:last_stream_event_at, System.monotonic_time(:millisecond) - 700_000)
      end)

      ref = :sys.get_state(pid).stream_ref
      send(pid, {:stream_timeout, id, ref})
      Process.sleep(50)

      state = :sys.get_state(pid)
      assert state.status == :thinking
      assert state.active_tool == "docker_compose"
    end

    test "stream_timeout on a silent, idle-handed stream reboots and clears transient state",
         %{id: id} do
      pid = agent_pid(id)

      :sys.replace_state(pid, fn s ->
        %{s | status: :thinking, active_tool: nil, stream_ref: make_ref()}
        |> Map.put(:last_stream_event_at, System.monotonic_time(:millisecond) - 700_000)
      end)

      ref = :sys.get_state(pid).stream_ref
      send(pid, {:stream_timeout, id, ref})
      Process.sleep(50)

      state = :sys.get_state(pid)
      assert state.status == :idle
      assert state.active_tool == nil
    end

    test "stream_error (non-CLI-exit) clears active_tool", %{id: id} do
      pid = agent_pid(id)

      :sys.replace_state(pid, fn s ->
        %{s | status: :thinking, active_tool: "docker_compose"}
      end)

      send(pid, {:stream_error, id, "some transient error"})
      Process.sleep(50)

      state = :sys.get_state(pid)
      assert state.status == :idle
      assert state.active_tool == nil
    end

    test "EXIT over @max_consecutive_crashes transitions to :crashed + clears active_tool", %{
      id: id
    } do
      pid = agent_pid(id)

      :sys.replace_state(pid, fn s ->
        s
        |> Map.put(:status, :thinking)
        |> Map.put(:active_tool, "docker_compose")
        |> Map.put(:consecutive_crashes, 5)
      end)

      send(pid, {:EXIT, self(), {:error, "fatal"}})
      assert_receive %Loopyard.Events.ChatAgent.StatusChanged{id: ^id, status: :crashed}, 500

      state = :sys.get_state(pid)
      assert state.status == :crashed
      assert state.active_tool == nil
    end

    test "EXIT under @max_consecutive_crashes transitions to :backoff + clears active_tool", %{
      id: id
    } do
      pid = agent_pid(id)

      :sys.replace_state(pid, fn s ->
        s
        |> Map.put(:status, :thinking)
        |> Map.put(:active_tool, "docker_compose")
        |> Map.put(:consecutive_crashes, 0)
      end)

      send(pid, {:EXIT, self(), {:error, "boom"}})
      assert_receive %Loopyard.Events.ChatAgent.StatusChanged{id: ^id, status: :backoff}, 500

      state = :sys.get_state(pid)
      # :backoff status means the retry was scheduled.
      assert state.status in [:backoff, :idle]
      # Either way, active_tool is gone.
      assert state.active_tool == nil
    end

    test "rate_limit :rejected clears active_tool", %{id: id} do
      pid = agent_pid(id)

      ref = make_ref()

      :sys.replace_state(pid, fn s ->
        %{s | status: :thinking, active_tool: "docker_compose", stream_ref: ref}
      end)

      send(
        pid,
        {:stream_event, id, ref,
         %Event.RateLimitStatus{
           status: :rejected,
           resets_at_ms: System.system_time(:millisecond) + 2_000,
           rate_limit_type: "five_hour"
         }}
      )

      assert_receive %Loopyard.Events.ChatAgent.StatusChanged{id: ^id, status: :rate_limited},
                     500

      state = :sys.get_state(pid)
      assert state.status == :rate_limited
      assert state.active_tool == nil
    end

    test "auth error clears active_tool", %{id: id} do
      pid = agent_pid(id)

      ref = make_ref()

      :sys.replace_state(pid, fn s ->
        %{s | status: :thinking, active_tool: "docker_compose", stream_ref: ref}
      end)

      send(
        pid,
        {:stream_event, id, ref,
         %Event.AuthStatus{is_authenticating: false, error: "token expired"}}
      )

      assert_receive %Loopyard.Events.ChatAgent.StatusChanged{id: ^id, status: :auth_expired},
                     500

      state = :sys.get_state(pid)
      assert state.status == :auth_expired
      assert state.active_tool == nil
    end

    test "init_resume clears active_tool (carrying stale :docker_compose from summary)", %{id: id} do
      pid = agent_pid(id)

      # Directly write a summary with a stale active_tool (mimic the
      # row ServiceManager would replay on Loopyard restart).
      orig = :sys.get_state(pid)

      summary = %{
        id: orig.id,
        name: orig.name,
        working_dir: orig.working_dir,
        bind_mount: orig.bind_mount,
        workspace_id: orig.workspace_id,
        started_at: orig.started_at,
        started_by: orig.started_by,
        last_activity_at: orig.last_activity_at,
        status: :idle,
        messages: [],
        tool_calls: 0,
        errors: 0,
        service_name: orig.service_name,
        model: nil,
        total_input_tokens: 0,
        total_output_tokens: 0,
        total_cache_read_tokens: 0,
        total_cost_usd: 0.0,
        active_tool: "docker_compose",
        turns: 0,
        claude_session_id: nil,
        rate_limit_status: :ok,
        rate_limit_resets_at_ms: nil,
        rate_limit_type: nil,
        auth_error: nil
      }

      :ets.insert(:chat_agents, {id, summary})
      ChatAgent.stop_agent(id)
      Process.sleep(30)

      {:ok, _} =
        Loopyard.TestHelpers.start_agent(
          id: id,
          name: "Restart State Test",
          started_by: "test",
          backend: RecordingBackend,
          resume: true
        )

      new_state = :sys.get_state(agent_pid(id))

      # init_resume's struct override explicitly sets active_tool: nil
      # — stale UI spinners must not survive a restart.
      assert new_state.active_tool == nil
    end
  end
end
