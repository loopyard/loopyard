defmodule BoomLooper.ChatAgent.SessionResumeTest do
  @moduledoc """
  Regression test for the conversation-amnesia bug.

  Since the first commit that introduced the Claude Code SDK backend
  (b1c6fdd, 2026-03-17), the ChatAgent held the CLI `session_id` only
  inside the live SDK Session GenServer. When that session was
  replaced — on crash-retry, auto-reconnect, user-triggered restart,
  or a BoomLooper server restart that replayed the agent log — the
  new CLI was spawned WITHOUT `resume: <session_id>` and the
  conversation reset. Users kept sending messages against a sidebar
  full of history the CLI had no memory of.

  This test pins down the fix on all four restart paths plus the
  server-restart-resume path.
  """

  use ExUnit.Case, async: false

  alias BoomLooper.ChatAgent
  alias BoomLooper.Agent.Event
  alias BoomLooper.TestSupport.RecordingBackend

  @moduletag timeout: 10_000

  setup do
    RecordingBackend.reset()

    Application.put_env(:boom_looper, :crash_backoff_base_ms, 0)
    on_exit(fn -> Application.delete_env(:boom_looper, :crash_backoff_base_ms) end)

    id = "resume-test-#{:rand.uniform(100_000)}"

    {:ok, _pid} =
      BoomLooper.TestHelpers.start_agent(
        id: id,
        name: "Resume Test",
        working_dir: File.cwd!(),
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
    case Registry.lookup(BoomLooper.ChatAgentRegistry, id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  describe "capturing claude_session_id from SessionResult" do
    test "session_id is pulled from the backend after each SessionResult and persisted",
         %{id: id} do
      pid = agent_pid(id)
      RecordingBackend.set_session_id("sess-abc-123")
      ref = make_ref()
      :sys.replace_state(pid, fn s -> %{s | stream_ref: ref} end)

      # Simulate a SessionResult event — what the ClaudeCode backend
      # emits after every turn. The handler should mirror the backend's
      # session_id onto ChatAgent state and into the ETS summary.
      send(
        pid,
        {:stream_event, id, ref,
         %Event.SessionResult{
           model: "claude-opus-4-7",
           input_tokens: 10,
           output_tokens: 20,
           cache_read_tokens: 0,
           cost_usd: 0.01,
           duration_ms: 1_000,
           num_turns: 1
         }}
      )

      # The handler persists synchronously via :sys.get_state waits.
      state = :sys.get_state(pid)
      assert state.claude_session_id == "sess-abc-123"

      [{^id, summary}] = :ets.lookup(:chat_agents, id)
      assert summary.claude_session_id == "sess-abc-123"
    end
  end

  describe "session_opts_with_resume across restart paths" do
    test "dispatch_retry_session passes resume: claude_session_id", %{id: id} do
      pid = agent_pid(id)

      # Seed the captured session_id (what SessionResult would have done).
      :sys.replace_state(pid, fn s ->
        s
        |> Map.put(:claude_session_id, "sess-retry-777")
        |> Map.put(:status, :thinking)
        |> Map.put(:consecutive_crashes, 1)
      end)

      # Drop the initial start_session call the setup made.
      RecordingBackend.reset()
      RecordingBackend.set_session_id("sess-retry-777")

      # Fire the retry directly (matching the guard — dead_session matches).
      original = :sys.get_state(pid).session
      send(pid, {:retry_session, 1, original})

      assert_receive %BoomLooper.Events.ChatAgent.StatusChanged{id: ^id, status: :idle}, 1_000

      [opts | _] = RecordingBackend.starts()
      assert Keyword.get(opts, :resume) == "sess-retry-777"
    end

    test "ensure_session_alive passes resume when session_id is set", %{id: id} do
      pid = agent_pid(id)

      # Kill the live session and set claude_session_id.
      :sys.replace_state(pid, fn s ->
        if s.session && Process.alive?(s.session), do: Process.exit(s.session, :kill)
        Process.sleep(10)

        s
        |> Map.put(:session, nil)
        |> Map.put(:claude_session_id, "sess-reconnect-42")
      end)

      RecordingBackend.reset()
      RecordingBackend.set_session_id("sess-reconnect-42")

      # ensure_session_alive runs at the top of every :send_message cast.
      ChatAgent.send_message(id, "hello")

      # Give the cast a moment to process.
      Process.sleep(100)

      starts = RecordingBackend.starts()
      assert starts != []
      first = List.first(starts)
      assert Keyword.get(first, :resume) == "sess-reconnect-42"
    end

    test "restart_session cast passes resume when session_id is set", %{id: id} do
      pid = agent_pid(id)

      :sys.replace_state(pid, fn s -> Map.put(s, :claude_session_id, "sess-manual-9") end)

      RecordingBackend.reset()
      RecordingBackend.set_session_id("sess-manual-9")

      GenServer.cast(pid, :restart_session)
      Process.sleep(100)

      [opts | _] = RecordingBackend.starts()
      assert Keyword.get(opts, :resume) == "sess-manual-9"
    end

    test "no claude_session_id → no resume option injected", %{id: id} do
      pid = agent_pid(id)

      :sys.replace_state(pid, fn s ->
        s
        |> Map.put(:claude_session_id, nil)
        |> Map.put(:status, :thinking)
      end)

      RecordingBackend.reset()
      original = :sys.get_state(pid).session
      send(pid, {:retry_session, 1, original})

      assert_receive %BoomLooper.Events.ChatAgent.StatusChanged{id: ^id, status: :idle}, 1_000

      [opts | _] = RecordingBackend.starts()
      refute Keyword.has_key?(opts, :resume)
    end
  end

  describe "server restart (init_resume)" do
    test "resumes with claude_session_id from the saved summary", %{id: id} do
      pid = agent_pid(id)

      # Simulate an agent that has been running for a while: seed ETS
      # with a summary that carries claude_session_id, then stop the
      # live GenServer and restart it via `resume: true` to mimic what
      # ServiceManager does after a BoomLooper server restart.
      :sys.replace_state(pid, fn s -> Map.put(s, :claude_session_id, "sess-server-restart") end)
      live_state = :sys.get_state(pid)
      summary = %{
        id: live_state.id,
        name: live_state.name,
        working_dir: live_state.working_dir,
        bind_mount: live_state.bind_mount,
        workspace_id: live_state.workspace_id,
        started_at: live_state.started_at,
        started_by: live_state.started_by,
        last_activity_at: live_state.last_activity_at,
        status: :idle,
        messages: [],
        tool_calls: 0,
        errors: 0,
        service_name: live_state.service_name,
        agent_type: live_state.agent_type,
        model: nil,
        total_input_tokens: 0,
        total_output_tokens: 0,
        total_cache_read_tokens: 0,
        total_cost_usd: 0.0,
        active_tool: nil,
        turns: 0,
        claude_session_id: "sess-server-restart"
      }

      :ets.insert(:chat_agents, {id, summary})

      # Stop the current agent and restart fresh via resume: true.
      ChatAgent.stop_agent(id)
      Process.sleep(50)

      RecordingBackend.reset()
      RecordingBackend.set_session_id("sess-server-restart")

      {:ok, _} =
        BoomLooper.TestHelpers.start_agent(
          id: id,
          name: "Resume Test",
          working_dir: File.cwd!(),
          started_by: "test",
          backend: RecordingBackend,
          resume: true
        )

      [opts | _] = RecordingBackend.starts()

      assert Keyword.get(opts, :resume) == "sess-server-restart",
             "init_resume must pass the saved claude_session_id as resume: so the new " <>
               "CLI continues the same conversation instead of spawning amnesiac"

      new_state = :sys.get_state(agent_pid(id))
      assert new_state.claude_session_id == "sess-server-restart"
    end
  end
end
