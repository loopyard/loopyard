defmodule Loopyard.ChatAgent.StreamHandler.RateLimit do
  @moduledoc """
  Rate-limit, auth-status, and context-window handling for the
  ChatAgent stream.

  Split out of `Loopyard.ChatAgent.StreamHandler` to keep that module
  under its size cap. These functions take `state` and return updated
  `state`, mirroring the StreamHandler contract. The formatting helpers
  (`format_reset/1`, `rate_limit_label/1`, `compute_rate_limit_wait_ms/1`)
  are re-exposed from StreamHandler via `defdelegate` so external
  callers (ChatAgent, context_panel) are unchanged.
  """

  require Logger

  alias Loopyard.Agent.Event
  alias Loopyard.ChatAgent.Persistence
  alias Loopyard.Events

  @ets_table :chat_agents

  # Max in-memory messages (matching ChatAgent's cap).
  @max_messages 1000

  # Context window warning threshold.
  @context_warn_threshold 0.85

  # Re-check at most this often. A weekly (seven_day) limit resets days out;
  # waiting until exactly then is right, but a single multi-day timer is fragile
  # (idle-reap, restart), so cap the poll — without spamming every 60s like before.
  @max_rate_limit_poll_ms 5 * 60 * 1000

  @doc """
  Compute the wait time in milliseconds before retrying after a rate limit.
  Public because ChatAgent.handle_cast(:send_message) also uses it.
  """
  def compute_rate_limit_wait_ms(resets_at_ms) when is_integer(resets_at_ms) do
    delta = resets_at_ms - System.system_time(:millisecond)

    cond do
      delta <= 0 -> 5_000
      true -> min(delta + 1_000, @max_rate_limit_poll_ms)
    end
  end

  def compute_rate_limit_wait_ms(_), do: 60_000

  @doc "Human-readable time until a rate-limit reset, e.g. \"in ~3 days\"."
  def format_reset(resets_at_ms) when is_integer(resets_at_ms) do
    delta = resets_at_ms - System.system_time(:millisecond)

    cond do
      delta <= 0 -> "any moment"
      delta < 90_000 -> "in ~#{div(delta, 1000)}s"
      delta < 5_400_000 -> "in ~#{max(1, div(delta, 60_000))} min"
      delta < 86_400_000 -> "in ~#{max(1, div(delta, 3_600_000))} hr"
      true -> "in ~#{max(1, div(delta, 86_400_000))} days"
    end
  end

  def format_reset(_), do: "shortly"

  @doc """
  Human-readable name for a rate-limit type. Accepts atom or string
  (`ClaudeCode` may hand back either) so callers don't have to normalize.
  Returns just the noun — callers add "limit" etc.
  """
  def rate_limit_label(type) do
    case to_string(type || "") do
      "seven_day" -> "weekly"
      "five_hour" -> "5-hour"
      "opus_weekly" -> "weekly Opus"
      "" -> "usage"
      other -> String.replace(other, "_", " ")
    end
  end

  @doc "True when the limit is one of the multi-day caps API credits sidestep."
  def weekly_limit?(type),
    do: to_string(type || "") =~ "week" or to_string(type || "") =~ "seven_day"

  # "(at ~92% of cap)" when utilization is known, else "".
  defp rate_limit_util_phrase(util) when is_number(util) and util > 0 do
    " (at ~#{round(util * 100)}% of cap)"
  end

  defp rate_limit_util_phrase(_), do: ""

  @doc """
  The chat-surfaced explanation for a rejection. Names the SPECIFIC
  limit (weekly / 5-hour / …), how close to the cap, whether overage
  credits are in play, and when it clears — because "you're rate
  limited" with no specifics is useless to someone who's always limited.
  """
  def rate_limit_message(%Event.RateLimitStatus{} = rl) do
    label = rate_limit_label(rl.rate_limit_type)
    reset = format_reset(rl.resets_at_ms)
    util = rate_limit_util_phrase(rl.utilization)

    overage = if rl.is_using_overage, do: " You're now into overage credits.", else: ""

    hint =
      if weekly_limit?(rl.rate_limit_type) do
        " (For heavy continuous use, switching the harness to API credits avoids the weekly cap.)"
      else
        ""
      end

    "Hit your #{label} Claude usage limit#{util} — resets #{reset}. " <>
      "I'll pick back up automatically when it clears.#{overage}#{hint}"
  end

  @doc """
  Handle a `%Event.RateLimitStatus{}` from the Claude CLI. Returns state.
  """
  def handle_rate_limit_event(state, %Event.RateLimitStatus{} = rl) do
    id = state.id

    :telemetry.execute(
      [:loopyard, :agent, :rate_limit],
      %{count: 1},
      %{agent_id: id, status: rl.status, rate_limit_type: rl.rate_limit_type}
    )

    case rl.status do
      :rejected ->
        wait_ms = compute_rate_limit_wait_ms(rl.resets_at_ms)
        # Only the FIRST rejection adds a chat message — every retry that's still
        # limited would otherwise re-spam the stream. The harness-status block
        # carries the live state after that.
        first? = state.rate_limit_status != :rejected
        Process.send_after(self(), {:rate_limit_retry, id}, wait_ms)

        state = %{
          state
          | status: :rate_limited,
            active_tool: nil,
            rate_limit_status: :rejected,
            rate_limit_resets_at_ms: rl.resets_at_ms,
            rate_limit_type: rl.rate_limit_type,
            rate_limit_utilization: rl.utilization
        }

        :ets.insert(@ets_table, {id, Loopyard.ChatAgent.summary(state)})
        Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: id, status: :rate_limited})

        if first? do
          Loopyard.EventLog.warning(
            "agent:#{state.name}",
            "Rate-limited (#{rate_limit_label(rl.rate_limit_type)}); resets #{format_reset(rl.resets_at_ms)}"
          )

          rl_msg = %{
            role: :system,
            content: rate_limit_message(rl),
            timestamp: DateTime.utc_now()
          }

          {state, rl_msg} = append_message(state, rl_msg)
          Persistence.persist_message(state, rl_msg)

          Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{
            agent_id: id,
            msg: rl_msg
          })

          state
        else
          state
        end

      :allowed_warning ->
        state = %{
          state
          | rate_limit_status: :warning,
            rate_limit_resets_at_ms: rl.resets_at_ms,
            rate_limit_type: rl.rate_limit_type,
            rate_limit_utilization: rl.utilization
        }

        :ets.insert(@ets_table, {id, Loopyard.ChatAgent.summary(state)})
        state

      :allowed ->
        was_rate_limited = state.rate_limit_status != :ok
        new_main_status = if state.status == :rate_limited, do: :idle, else: state.status

        state = %{
          state
          | status: new_main_status,
            rate_limit_status: :ok,
            rate_limit_resets_at_ms: nil,
            rate_limit_type: nil,
            rate_limit_utilization: nil
        }

        :ets.insert(@ets_table, {id, Loopyard.ChatAgent.summary(state)})

        if was_rate_limited do
          Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{
            id: id,
            status: new_main_status
          })
        end

        state

      _other ->
        state
    end
  end

  # Base + cap for the auth self-heal backoff. Auth failures are NOT terminal:
  # we keep re-sourcing credentials on a growing-but-capped interval so the agent
  # recovers the moment a valid token lands (pushed via the env endpoint, or
  # refreshed some other way) WITHOUT anyone clicking Restart. Capped at 2 min so
  # a persistently-bad token isn't a hot loop.
  @auth_retry_base_ms 10_000
  @auth_retry_max_ms 120_000

  @doc false
  def auth_retry_backoff_ms(attempt) when is_integer(attempt) and attempt > 0 do
    min(
      Loopyard.Retry.backoff_ms(attempt, {:exponential, @auth_retry_base_ms}),
      @auth_retry_max_ms
    )
  end

  @doc """
  Handle a `%Event.AuthStatus{}` from the Claude CLI. Returns state.
  """
  def handle_auth_status_event(state, %Event.AuthStatus{error: nil, is_authenticating: true}) do
    state
  end

  def handle_auth_status_event(state, %Event.AuthStatus{error: error}) when is_binary(error) do
    id = state.id
    # Only announce the failure on the FIRST transition into auth_expired — a
    # retry that re-fails would otherwise re-spam the chat every backoff.
    first? = state.status != :auth_expired
    attempt = Map.get(state, :auth_retry_count, 0) + 1

    :telemetry.execute(
      [:loopyard, :agent, :auth_expired],
      %{count: 1, attempt: attempt},
      %{agent_id: id, error: error}
    )

    Loopyard.EventLog.error("agent:#{state.name}", "Claude auth failed: #{error}")

    state =
      %{
        state
        | status: :auth_expired,
          active_tool: nil,
          auth_error: error,
          errors: state.errors + 1
      }
      |> Map.put(:auth_retry_count, attempt)

    # Schedule the self-heal retry (re-sources credentials + resumes). Fires in
    # THIS GenServer, so send_after(self()) is correct.
    Process.send_after(self(), {:auth_retry, attempt}, auth_retry_backoff_ms(attempt))

    state =
      if first? do
        auth_msg = %{
          role: :error,
          content:
            "Claude authentication failed: #{error}. " <>
              "WHY: the harness couldn't authenticate — usually an expired or rotated " <>
              "CLAUDE_CODE_OAUTH_TOKEN in this workstation. " <>
              "CONSEQUENCE: this turn was dropped; your conversation is preserved. " <>
              "ACTION: paste a fresh token on the Operator page (run `claude setup-token`, " <>
              "then use the \"Update token\" card at the top) — every agent restarts and " <>
              "resumes automatically once it lands.",
          timestamp: DateTime.utc_now()
        }

        {state, auth_msg} = append_message(state, auth_msg)
        Persistence.persist_message(state, auth_msg)

        Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{
          agent_id: id,
          msg: auth_msg
        })

        state
      else
        state
      end

    :ets.insert(@ets_table, {id, Loopyard.ChatAgent.summary(state)})
    Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: id, status: :auth_expired})
    state
  end

  def handle_auth_status_event(state, _other), do: state

  @doc """
  Context window size (in tokens) for a known model, with a conservative
  default + telemetry/log for unknown models.
  """
  def context_window_for(model) when is_binary(model) do
    windows = Application.get_env(:loopyard, :model_windows, %{})

    Map.get(windows, model) ||
      Enum.find_value(windows, fn {prefix, size} ->
        if String.starts_with?(model, prefix), do: size
      end) ||
      unknown_model_window(model)
  end

  def context_window_for(_), do: model_window_default()

  defp model_window_default, do: Application.get_env(:loopyard, :model_window_default, 200_000)

  # A model we don't have a window for. DON'T silently miscompute (a 0 froze
  # utilization at a stale value; a wrong default hid a 6x overflow). Assume the
  # conservative default but SCREAM so it gets added to config.
  defp unknown_model_window(model) do
    default = model_window_default()

    :telemetry.execute(
      [:loopyard, :agent, :unknown_model_window],
      %{default: default},
      %{model: model}
    )

    Logger.warning(
      "[ContextWindow] Model #{inspect(model)} has no entry in :model_windows config — " <>
        "assuming #{default} tokens. Context utilization + auto-compaction will be off for it " <>
        "until you add the real window to config/config.exs."
    )

    default
  end

  @doc """
  One-shot warning when context utilization crosses the threshold.
  Returns state.
  """
  def maybe_warn_context_full(state, id, utilization)
      when utilization >= @context_warn_threshold do
    if state.context_warning_sent do
      state
    else
      pct = round(utilization * 100)

      :telemetry.execute(
        [:loopyard, :agent, :context_warning],
        %{utilization: utilization},
        %{agent_id: id, model: state.model}
      )

      Loopyard.EventLog.warning(
        "agent:#{state.name}",
        "Context window #{pct}% full (model=#{state.model || "?"})"
      )

      %{state | context_warning_sent: true}
    end
  end

  def maybe_warn_context_full(state, _id, _utilization), do: state

  # Inline append_message — same logic as ChatAgent's private version.
  # Prepends to reversed list for O(1) append, assigns ID if missing.
  defp append_message(state, msg) do
    msg =
      Map.put_new_lazy(msg, :id, fn ->
        :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
      end)

    reversed = [msg | state.messages]

    reversed =
      if length(reversed) > @max_messages, do: Enum.take(reversed, @max_messages), else: reversed

    {%{state | messages: reversed}, msg}
  end
end
