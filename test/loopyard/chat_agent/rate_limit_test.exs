defmodule Loopyard.ChatAgent.RateLimitTest do
  @moduledoc """
  Surface #10 of plans/agent-sanity.md.

  The Claude API can return rate-limit events (`ClaudeCode.Message.RateLimitEvent`)
  and auth failures (`ClaudeCode.Message.AuthStatusMessage`). Pre-fix those
  fell through the backend's `translate(_)` catchall and the agent never
  saw them as distinct states — either silent-drop or crash-loop against a
  known-hard limit. This test pins down the new behavior:

    * `:rejected` rate limit → flip status to `:rate_limited`, schedule
      auto-retry at `resets_at_ms`, surface it in the chat.
    * `:allowed_warning` → record the warning, keep the main status.
    * `:allowed` → clear any prior rate-limit state and unblock.
    * auth error → flip to `:auth_expired`, stop retrying, surface it.
    * `send_message` while `:rate_limited` or `:auth_expired` → no CLI
      hit; just log the message + an explainer so users see they didn't
      silently lose their input.
  """

  use ExUnit.Case, async: false

  alias Loopyard.ChatAgent
  alias Loopyard.Agent.Event
  alias Loopyard.TestSupport.RecordingBackend

  @moduletag timeout: 10_000

  setup do
    RecordingBackend.reset()

    id = "rl-test-#{:rand.uniform(100_000)}"

    {:ok, _pid} =
      Loopyard.TestHelpers.start_agent(
        id: id,
        name: "Rate Limit Test",
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
    case Registry.lookup(Loopyard.ChatAgentRegistry, id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  describe "RateLimitStatus handling" do
    test ":rejected transitions to :rate_limited and schedules auto-retry", %{id: id} do
      pid = agent_pid(id)

      # resets_at_ms a short window in the future — long enough to
      # observe both the transition and the auto-clear, short enough
      # to keep the suite fast. The behavior is the same at any window;
      # we only need to assert that the scheduled retry fires.
      resets_at = System.system_time(:millisecond) + 200

      ref = make_ref()
      :sys.replace_state(pid, fn s -> %{s | stream_ref: ref} end)

      send(
        pid,
        {:stream_event, id, ref,
         %Event.RateLimitStatus{
           status: :rejected,
           resets_at_ms: resets_at,
           rate_limit_type: "five_hour",
           utilization: 1.0,
           is_using_overage: false
         }}
      )

      assert_receive %Loopyard.Events.ChatAgent.StatusChanged{id: ^id, status: :rate_limited},
                     500

      state = :sys.get_state(pid)
      assert state.status == :rate_limited
      assert state.rate_limit_status == :rejected
      assert state.rate_limit_resets_at_ms == resets_at
      assert state.rate_limit_type == "five_hour"

      # The inline system message names the SPECIFIC limit (5-hour here,
      # from rate_limit_type "five_hour") and the utilization — a generic
      # "you're rate limited" is useless to someone who's always limited.
      assert Enum.any?(state.messages, fn m ->
               m.role == :system and String.contains?(m.content, "5-hour") and
                 String.contains?(m.content, "% of cap")
             end)

      # After the resets_at window, the scheduled :rate_limit_retry should
      # flip the agent back to :idle. ~1s headroom on top of the 200ms
      # window keeps the test deterministic without burning seconds.
      assert_receive %Loopyard.Events.ChatAgent.StatusChanged{id: ^id, status: :idle}, 1_500
      state_after = :sys.get_state(pid)
      assert state_after.status == :idle
      assert state_after.rate_limit_status == :ok
      assert state_after.rate_limit_resets_at_ms == nil
    end

    test ":allowed_warning does not change main status but records warning",
         %{id: id} do
      pid = agent_pid(id)
      ref = make_ref()
      :sys.replace_state(pid, fn s -> %{s | stream_ref: ref} end)

      send(
        pid,
        {:stream_event, id, ref,
         %Event.RateLimitStatus{
           status: :allowed_warning,
           resets_at_ms: nil,
           rate_limit_type: "five_hour",
           utilization: 0.85,
           is_using_overage: false
         }}
      )

      # Settle.
      Process.sleep(50)

      state = :sys.get_state(pid)
      assert state.status == :idle
      assert state.rate_limit_status == :warning
      assert state.rate_limit_type == "five_hour"

      # No StatusChanged should have fired — main status didn't change.
      refute_receive %Loopyard.Events.ChatAgent.StatusChanged{id: ^id}, 100
    end

    test ":allowed clears prior :rate_limited state and broadcasts :idle",
         %{id: id} do
      pid = agent_pid(id)

      ref = make_ref()

      :sys.replace_state(pid, fn s ->
        %{
          s
          | status: :rate_limited,
            rate_limit_status: :rejected,
            rate_limit_resets_at_ms: System.system_time(:millisecond) + 10_000,
            rate_limit_type: "five_hour",
            stream_ref: ref
        }
      end)

      send(
        pid,
        {:stream_event, id, ref,
         %Event.RateLimitStatus{status: :allowed, resets_at_ms: nil, rate_limit_type: nil}}
      )

      assert_receive %Loopyard.Events.ChatAgent.StatusChanged{id: ^id, status: :idle}, 500
      state = :sys.get_state(pid)
      assert state.status == :idle
      assert state.rate_limit_status == :ok
      assert state.rate_limit_resets_at_ms == nil
      assert state.rate_limit_type == nil
    end
  end

  describe "AuthStatus handling" do
    test "error transitions to :auth_expired and stops retrying", %{id: id} do
      pid = agent_pid(id)
      ref = make_ref()
      :sys.replace_state(pid, fn s -> %{s | stream_ref: ref} end)

      send(
        pid,
        {:stream_event, id, ref,
         %Event.AuthStatus{
           is_authenticating: false,
           error: "token expired",
           output: ["Please re-authenticate"]
         }}
      )

      assert_receive %Loopyard.Events.ChatAgent.StatusChanged{id: ^id, status: :auth_expired},
                     500

      state = :sys.get_state(pid)
      assert state.status == :auth_expired
      assert state.auth_error == "token expired"
      assert state.errors >= 1
    end

    test "is_authenticating=true with no error is a no-op", %{id: id} do
      pid = agent_pid(id)
      ref = make_ref()
      :sys.replace_state(pid, fn s -> %{s | stream_ref: ref} end)
      original = :sys.get_state(pid)

      send(
        pid,
        {:stream_event, id, ref,
         %Event.AuthStatus{is_authenticating: true, error: nil, output: ["Authenticating..."]}}
      )

      Process.sleep(50)

      state = :sys.get_state(pid)
      assert state.status == original.status
      assert state.auth_error == nil
      refute_receive %Loopyard.Events.ChatAgent.StatusChanged{id: ^id}, 100
    end
  end

  describe "send_message while blocked" do
    test "send_message while :rate_limited queues without touching the chat stream",
         %{id: id} do
      pid = agent_pid(id)

      :sys.replace_state(pid, fn s ->
        %{
          s
          | status: :rate_limited,
            rate_limit_status: :rejected,
            rate_limit_resets_at_ms: System.system_time(:millisecond) + 60_000,
            rate_limit_type: "five_hour"
        }
      end)

      ChatAgent.send_message(id, "hey")
      Process.sleep(100)

      state = :sys.get_state(pid)
      # Rate-limiting is a turn-execution concern, not an inbox one: the agent
      # is "busy", so the message PARKS in the queue (no stream, no chat bubble,
      # no "Holding" explainer). It enters the chat only when it drains.
      assert state.status == :rate_limited
      assert state.pending_sends == ["hey"]
      refute Enum.any?(state.messages, &(&1.role == :user and &1.content == "hey"))

      refute Enum.any?(state.messages, fn m ->
               m.role == :system and String.contains?(m.content || "", "Holding")
             end)
    end

    test "send_message while :auth_expired queues + posts the auth-fix card, no CLI hit",
         %{id: id} do
      pid = agent_pid(id)

      :sys.replace_state(pid, fn s ->
        %{s | status: :auth_expired, auth_error: "token expired"}
      end)

      ChatAgent.send_message(id, "hey")
      Process.sleep(100)

      state = :sys.get_state(pid)
      assert state.status == :auth_expired
      # Queued for delivery after re-auth (the queue band shows it) — not
      # appended as a user message yet (that happens on actual send).
      assert "hey" in state.pending_sends

      # The chat's answer is the auth-fix MINI-APP card, exactly one.
      assert Enum.count(
               state.messages,
               &(&1[:role] == :auth_fix and &1[:status] == :pending)
             ) == 1

      # Repeat sends don't stack duplicate cards.
      ChatAgent.send_message(id, "hello again")
      Process.sleep(100)
      state = :sys.get_state(pid)

      assert Enum.count(
               state.messages,
               &(&1[:role] == :auth_fix and &1[:status] == :pending)
             ) == 1

      assert "hello again" in state.pending_sends
    end
  end

  describe "summary/1 exposes rate-limit + auth fields" do
    test "ETS summary carries the new fields", %{id: id} do
      pid = agent_pid(id)

      resets_at = System.system_time(:millisecond) + 60_000

      :sys.replace_state(pid, fn s ->
        %{
          s
          | status: :rate_limited,
            rate_limit_status: :rejected,
            rate_limit_resets_at_ms: resets_at,
            rate_limit_type: "five_hour",
            auth_error: nil
        }
      end)

      # Trigger an ETS write via any path — just read+write via
      # GenServer.call.
      GenServer.call(pid, :get_state)
      _ = :sys.get_state(pid)

      # Force a summary write by bumping through handle_info paths.
      # Or read the current ETS row — the most recent SessionResult or
      # StatusChanged would have inserted. Instead, use append_external
      # which guarantees a summary write.
      ChatAgent.append_message_ets(id, %{
        role: :system,
        content: "probe",
        timestamp: DateTime.utc_now()
      })

      Process.sleep(50)

      [{^id, summary}] = :ets.lookup(:chat_agents, id)
      assert summary.status == :rate_limited
      assert summary.rate_limit_status == :rejected
      assert summary.rate_limit_resets_at_ms == resets_at
      assert summary.rate_limit_type == "five_hour"
      assert summary.auth_error == nil
    end
  end
end
