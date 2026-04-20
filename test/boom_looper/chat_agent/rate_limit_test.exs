defmodule BoomLooper.ChatAgent.RateLimitTest do
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

  alias BoomLooper.ChatAgent
  alias BoomLooper.Agent.Event
  alias BoomLooper.TestSupport.RecordingBackend

  @moduletag timeout: 10_000

  setup do
    RecordingBackend.reset()

    id = "rl-test-#{:rand.uniform(100_000)}"

    {:ok, _pid} =
      BoomLooper.TestHelpers.start_agent(
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
    case Registry.lookup(BoomLooper.ChatAgentRegistry, id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  describe "RateLimitStatus handling" do
    test ":rejected transitions to :rate_limited and schedules auto-retry", %{id: id} do
      pid = agent_pid(id)

      # resets_at_ms 2s in the future — easy to observe both the
      # transition and the auto-clear.
      resets_at = System.system_time(:millisecond) + 2_000

      send(
        pid,
        {:stream_event, id,
         %Event.RateLimitStatus{
           status: :rejected,
           resets_at_ms: resets_at,
           rate_limit_type: "five_hour",
           utilization: 1.0,
           is_using_overage: false
         }}
      )

      assert_receive %BoomLooper.Events.ChatAgent.StatusChanged{id: ^id, status: :rate_limited},
                     500

      state = :sys.get_state(pid)
      assert state.status == :rate_limited
      assert state.rate_limit_status == :rejected
      assert state.rate_limit_resets_at_ms == resets_at
      assert state.rate_limit_type == "five_hour"

      # The inline system message is appended for UI visibility (do NOT
      # rely on it being a specific wording — just assert it's there).
      assert Enum.any?(state.messages, fn m ->
               m.role == :system and String.contains?(m.content, "Rate-limited")
             end)

      # After the resets_at window, the scheduled :rate_limit_retry should
      # flip the agent back to :idle. We picked 2s — give it 3s headroom.
      assert_receive %BoomLooper.Events.ChatAgent.StatusChanged{id: ^id, status: :idle}, 3_500
      state_after = :sys.get_state(pid)
      assert state_after.status == :idle
      assert state_after.rate_limit_status == :ok
      assert state_after.rate_limit_resets_at_ms == nil
    end

    test ":allowed_warning does not change main status but records warning",
         %{id: id} do
      pid = agent_pid(id)

      send(
        pid,
        {:stream_event, id,
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
      refute_receive %BoomLooper.Events.ChatAgent.StatusChanged{id: ^id}, 100
    end

    test ":allowed clears prior :rate_limited state and broadcasts :idle",
         %{id: id} do
      pid = agent_pid(id)

      :sys.replace_state(pid, fn s ->
        %{s |
          status: :rate_limited,
          rate_limit_status: :rejected,
          rate_limit_resets_at_ms: System.system_time(:millisecond) + 10_000,
          rate_limit_type: "five_hour"
        }
      end)

      send(
        pid,
        {:stream_event, id,
         %Event.RateLimitStatus{status: :allowed, resets_at_ms: nil, rate_limit_type: nil}}
      )

      assert_receive %BoomLooper.Events.ChatAgent.StatusChanged{id: ^id, status: :idle}, 500
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

      send(
        pid,
        {:stream_event, id,
         %Event.AuthStatus{
           is_authenticating: false,
           error: "token expired",
           output: ["Please re-authenticate"]
         }}
      )

      assert_receive %BoomLooper.Events.ChatAgent.StatusChanged{id: ^id, status: :auth_expired},
                     500

      state = :sys.get_state(pid)
      assert state.status == :auth_expired
      assert state.auth_error == "token expired"
      assert state.errors >= 1
    end

    test "is_authenticating=true with no error is a no-op", %{id: id} do
      pid = agent_pid(id)
      original = :sys.get_state(pid)

      send(
        pid,
        {:stream_event, id,
         %Event.AuthStatus{is_authenticating: true, error: nil, output: ["Authenticating..."]}}
      )

      Process.sleep(50)

      state = :sys.get_state(pid)
      assert state.status == original.status
      assert state.auth_error == nil
      refute_receive %BoomLooper.Events.ChatAgent.StatusChanged{id: ^id}, 100
    end
  end

  describe "send_message while blocked" do
    test "send_message while :rate_limited does not spawn a stream task",
         %{id: id} do
      pid = agent_pid(id)

      :sys.replace_state(pid, fn s ->
        %{s |
          status: :rate_limited,
          rate_limit_status: :rejected,
          rate_limit_resets_at_ms: System.system_time(:millisecond) + 60_000,
          rate_limit_type: "five_hour"
        }
      end)

      # Before sending, record how many Backend.stream calls happened.
      # RecordingBackend only records start_session; it returns [] from
      # stream. Easier signal: assert status stays :rate_limited after
      # the send (a real CLI hit would transition through :thinking).
      ChatAgent.send_message(id, "hey")
      Process.sleep(100)

      state = :sys.get_state(pid)
      assert state.status == :rate_limited

      # Both the user message AND the "Holding your message" explainer
      # should appear.
      assert Enum.any?(state.messages, &(&1.role == :user and &1.content == "hey"))

      assert Enum.any?(state.messages, fn m ->
               m.role == :system and String.contains?(m.content, "Holding your message")
             end)
    end

    test "send_message while :auth_expired surfaces an error, no CLI hit",
         %{id: id} do
      pid = agent_pid(id)

      :sys.replace_state(pid, fn s ->
        %{s | status: :auth_expired, auth_error: "token expired"}
      end)

      ChatAgent.send_message(id, "hey")
      Process.sleep(100)

      state = :sys.get_state(pid)
      assert state.status == :auth_expired
      assert Enum.any?(state.messages, &(&1.role == :user and &1.content == "hey"))

      assert Enum.any?(state.messages, fn m ->
               m.role == :error and String.contains?(m.content, "auth is expired")
             end)
    end
  end

  describe "summary/1 exposes rate-limit + auth fields" do
    test "ETS summary carries the new fields", %{id: id} do
      pid = agent_pid(id)

      resets_at = System.system_time(:millisecond) + 60_000
      :sys.replace_state(pid, fn s ->
        %{s |
          status: :rate_limited,
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
      ChatAgent.append_message_ets(id, %{role: :system, content: "probe", timestamp: DateTime.utc_now()})
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
