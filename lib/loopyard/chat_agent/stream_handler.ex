defmodule Loopyard.ChatAgent.StreamHandler do
  @moduledoc """
  Processes Claude SDK stream events on behalf of ChatAgent.

  Contains the logic for handling each event type (Text, ToolCall,
  ToolResult, TextDelta, SessionResult, RateLimitStatus, AuthStatus)
  as well as stream lifecycle events (done, error, timeout).

  The GenServer `handle_info` clauses stay in ChatAgent — this module
  provides pure-ish functions that take state and return state.

  For functions that need to drain the pending-sends queue (which
  requires calling ChatAgent's private `send_message_normal/2`),
  the return value is `{:drain, text, state}` or `{:noreply, state}`
  so the caller can dispatch accordingly.
  """

  require Logger

  alias Loopyard.Agent.Event
  alias Loopyard.ChatAgent.{Persistence, SessionManager}
  alias Loopyard.Events

  @ets_table :chat_agents

  # Loop-detection threshold: same tool + same input N times in a row.
  @tool_loop_threshold 5

  # Runaway cap: total tool calls in a single turn.
  @turn_tool_limit 50

  # Context window warning threshold.
  @context_warn_threshold 0.85

  # Max in-memory messages (matching ChatAgent's cap).
  @max_messages 1000

  # Published Claude model window sizes.
  @context_windows %{
    "claude-opus-4-7" => 1_000_000,
    "claude-opus-4-7-20250929" => 1_000_000,
    "claude-opus-4-6" => 1_000_000,
    "claude-opus-4-5" => 1_000_000,
    "claude-sonnet-4-6" => 200_000,
    "claude-sonnet-4-5" => 200_000,
    "claude-sonnet-4-5-20250929" => 200_000,
    "claude-haiku-4-5" => 200_000,
    "claude-haiku-4-5-20251001" => 200_000
  }

  # --- Public API ---

  @doc """
  Process a single stream event. Returns updated state.
  """
  def process_event(%Event.Text{text: content}, state) do
    now = DateTime.utc_now()
    id = state.id
    assistant_msg = %{role: :assistant, content: content, timestamp: now}
    {state, assistant_msg} = append_message(state, assistant_msg)
    # Full text arrived — clear any accumulated partial so a
    # subsequent stream_error/timeout doesn't re-emit it.
    state = %{state | last_activity_at: now, in_flight_partial: ""}
    Persistence.persist_message(state, assistant_msg)

    Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{
      agent_id: id,
      msg: assistant_msg
    })

    state
  end

  def process_event(%Event.ToolCall{name: tool_name, input: tool_input}, state) do
    now = DateTime.utc_now()
    id = state.id
    tool_msg = %{role: :tool, tool: tool_name, input: tool_input, timestamp: now}
    {state, tool_msg} = append_message(state, tool_msg)

    state = %{
      state
      | last_activity_at: now,
        tool_calls: state.tool_calls + 1,
        active_tool: tool_name,
        tool_calls_this_turn: state.tool_calls_this_turn + 1
    }

    # Loop detection: same tool + same input N times in a row
    state = maybe_detect_tool_loop(state, id, tool_name, tool_input)

    # Runaway cap: even if individual calls differ, a 50+ tool-call
    # turn is almost always the agent flailing. Warn once.
    state = maybe_detect_tool_runaway(state, id)

    Persistence.persist_message(state, tool_msg)
    Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{agent_id: id, msg: tool_msg})
    state
  end

  def process_event(%Event.ToolResult{content: content, is_error: is_error}, state) do
    now = DateTime.utc_now()
    id = state.id
    result_msg = %{role: :tool_result, content: content, is_error: is_error, timestamp: now}
    {state, result_msg} = append_message(state, result_msg)
    state = %{state | last_activity_at: now, active_tool: nil}
    Persistence.persist_message(state, result_msg)

    Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{
      agent_id: id,
      msg: result_msg
    })

    state
  end

  def process_event(%Event.TextDelta{text: text}, state) do
    id = state.id
    Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.TextDelta{agent_id: id, text: text})
    %{state | in_flight_partial: state.in_flight_partial <> (text || "")}
  end

  def process_event(%Event.Thinking{thinking: thinking}, state) do
    now = DateTime.utc_now()
    msg = %{role: :thinking, content: thinking, timestamp: now}
    {state, msg} = append_message(state, msg)
    Persistence.persist_message(state, msg)

    Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{
      agent_id: state.id,
      msg: msg
    })

    state
  end

  def process_event(%Event.ThinkingDelta{thinking: thinking}, state) do
    # Broadcast on a separate channel so the LV can stream thinking
    # into its own assign without mixing with the response text.
    Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.StreamOutput{
      agent_id: state.id,
      data: thinking || "",
      title: "__thinking__",
      msg_id: "__thinking__"
    })

    state
  end

  def process_event(%Event.ServerTool{name: name, input: input}, state) do
    now = DateTime.utc_now()
    msg = %{role: :tool, tool: "server__#{name}", input: input, timestamp: now}
    {state, msg} = append_message(state, msg)
    Persistence.persist_message(state, msg)

    Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{
      agent_id: state.id,
      msg: msg
    })

    %{state | last_activity_at: now, active_tool: "server__#{name}"}
  end

  def process_event(%Event.SystemEvent{}, state) do
    # System events (init, compaction, hooks) carry useful metadata but
    # are not human-readable. Don't dump them into the chat.
    state
  end

  def process_event(%Event.SessionResult{} = result, state) do
    id = state.id

    claude_sid = state.backend.session_id(state.session) || state.claude_session_id

    window = context_window_for(result.model || state.model)

    utilization =
      if window > 0 do
        (result.input_tokens + result.cache_read_tokens) / window
      else
        state.context_utilization
      end

    state = %{
      state
      | model: result.model || state.model,
        total_input_tokens: state.total_input_tokens + result.input_tokens,
        total_output_tokens: state.total_output_tokens + result.output_tokens,
        total_cache_read_tokens: state.total_cache_read_tokens + result.cache_read_tokens,
        total_cost_usd: state.total_cost_usd + result.cost_usd,
        claude_session_id: claude_sid,
        context_utilization: utilization
    }

    state = maybe_warn_context_full(state, id, utilization)

    :ets.insert(@ets_table, {id, Loopyard.ChatAgent.summary(state)})
    Persistence.persist_agent(state, &Loopyard.ChatAgent.summary/1)
    Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: id, status: state.status})
    state
  end

  def process_event(%Event.RateLimitStatus{} = rl, state) do
    handle_rate_limit_event(state, rl)
  end

  def process_event(%Event.AuthStatus{} = auth, state) do
    handle_auth_status_event(state, auth)
  end

  def process_event(_other, state), do: state

  @doc """
  Handle a clean stream completion. Returns `{:drain, text, state}` if
  there's a pending send to dispatch, or `{:noreply, state}` otherwise.
  """
  def on_stream_done(state) do
    id = state.id

    state = %{
      state
      | status: :idle,
        active_tool: nil,
        turns: state.turns + 1,
        in_flight_partial: "",
        context_warning_sent: false,
        last_tool_call: nil,
        tool_calls_this_turn: 0,
        tool_runaway_warned: false
    }

    state = Map.put(state, :consecutive_crashes, 0)

    # Detect empty responses when context is full — auto-restart the
    # session with a summary so the conversation continues instead of
    # silently dying.
    if state.context_utilization >= 1.0 && empty_last_response?(state) do
      # Brief status so the user knows why there's a pause
      status_msg = %{
        role: :system,
        content: "Refreshing context...",
        timestamp: DateTime.utc_now()
      }

      {state, status_msg} = append_message(state, status_msg)

      Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{
        agent_id: id,
        msg: status_msg
      })

      # Find the user's last message so we can re-send it after restart
      last_user_msg =
        state.messages
        |> Enum.filter(&(&1.role == :user))
        |> List.last()

      :ets.insert(@ets_table, {id, Loopyard.ChatAgent.summary(state)})
      Persistence.persist_agent(state, &Loopyard.ChatAgent.summary/1)

      {:auto_restart_context, last_user_msg && last_user_msg.content, state}
    else
      # If the agent finished a turn without producing any visible
      # response, tell the user instead of silently going idle.
      state =
        if empty_last_response?(state) do
          no_response_msg = %{
            role: :system,
            content:
              "Agent completed without a visible response. Try rephrasing or sending your message again.",
            timestamp: DateTime.utc_now()
          }

          {state, no_response_msg} = append_message(state, no_response_msg)

          Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{
            agent_id: id,
            msg: no_response_msg
          })

          state
        else
          state
        end

      :ets.insert(@ets_table, {id, Loopyard.ChatAgent.summary(state)})
      Persistence.persist_agent(state, &Loopyard.ChatAgent.summary/1)
      Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: id, status: :idle})
      drain_pending_sends(state)
    end
  end

  @doc """
  Handle a stream error. Returns `{:drain, text, state}` or `{:noreply, state}`.
  """
  def on_stream_error(state, reason) do
    id = state.id
    now = DateTime.utc_now()

    Loopyard.EventLog.error("agent:#{state.name}", "Stream error: #{reason}")

    # Finalize any partial assistant text so the user doesn't lose it
    # on browser refresh.
    state = finalize_partial_on_stream_interrupt(state, id, :error)

    # Count recent crashes (within last 60 seconds)
    recent_crashes =
      state.messages
      |> Enum.filter(fn m ->
        m.role == :system && m.content == "Agent crashed — restarting..." &&
          DateTime.diff(now, m.timestamp, :second) < 60
      end)
      |> length()

    if is_binary(reason) && String.contains?(reason, "CLI session exited") && recent_crashes < 2 do
      # CLI died — restart session and resume the same conversation
      state = %{state | last_activity_at: now, errors: state.errors + 1}

      case state.backend.start_session(SessionManager.build_resume_opts(state)) do
        {:ok, new_session} ->
          recovered_msg =
            if is_binary(state.claude_session_id) do
              %{
                role: :system,
                content:
                  "Agent session restarted automatically (resumed conversation #{String.slice(state.claude_session_id, 0..7)}…).",
                timestamp: DateTime.utc_now()
              }
            else
              %{
                role: :system,
                content: "Agent session restarted automatically.",
                timestamp: DateTime.utc_now()
              }
            end

          {state, recovered_msg} =
            append_message(
              SessionManager.track_os_pid(%{
                state
                | session: new_session,
                  status: :idle,
                  active_tool: nil
              }),
              recovered_msg
            )

          Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{
            agent_id: id,
            msg: recovered_msg
          })

          Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: id, status: :idle})

          if is_nil(state.claude_session_id) do
            {:build_resume, state}
          else
            drain_pending_sends(state)
          end

        {:error, reason} ->
          fail_msg = %{
            role: :error,
            content:
              "CLI session crashed and failed to restart: #{inspect(reason)}. " <>
                "WHY: the CLI died mid-stream, and the second attempt to spawn a new one failed. " <>
                "CONSEQUENCE: this agent can't respond until the CLI is restored. " <>
                "ACTION: click Restart in the sidebar. If that also fails, the agent harness " <>
                "may be misconfigured — verify the harness is installed in the container and re-authenticate.",
            timestamp: DateTime.utc_now()
          }

          {state, fail_msg} = append_message(state, fail_msg)
          state = %{state | status: :idle, active_tool: nil}

          Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{
            agent_id: id,
            msg: fail_msg
          })

          Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: id, status: :idle})
          drain_pending_sends(state)
      end
    else
      error_msg = %{
        role: :error,
        content:
          "Stream error: #{reason}. " <>
            "WHY: the CLI reported an unrecoverable error mid-stream (common: MCP tool " <>
            "crash, payload too big, malformed tool response). " <>
            "CONSEQUENCE: the in-flight turn was dropped. Prior context is preserved. " <>
            "ACTION: send another message — the agent will retry. If the same error " <>
            "recurs, check /system/events for details.",
        timestamp: now
      }

      {state, error_msg} = append_message(state, error_msg)

      state = %{
        state
        | status: :idle,
          active_tool: nil,
          last_activity_at: now,
          errors: state.errors + 1
      }

      Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{
        agent_id: id,
        msg: error_msg
      })

      Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: id, status: :idle})
      drain_pending_sends(state)
    end
  end

  @doc """
  Handle a stream timeout. Returns `{:drain, text, state}` or `{:noreply, state}`.
  """
  def on_stream_timeout(state) do
    id = state.id

    Loopyard.EventLog.warning(
      "agent:#{state.name}",
      "Stream timed out after 10m — rebooting the CLI and resuming the conversation"
    )

    # Finalize any partial text the stream produced before the timeout
    state = finalize_partial_on_stream_interrupt(state, id, :timeout)

    error_msg = %{
      role: :system,
      content:
        "The harness went silent for 10 minutes — a tool call hung or the CLI deadlocked. " <>
          "Loopyard is rebooting the CLI and resuming this conversation; your chat history is " <>
          "preserved. Any messages you queued will run on the fresh session.",
      timestamp: DateTime.utc_now()
    }

    {state, error_msg} = append_message(state, error_msg)
    state = %{state | status: :idle, active_tool: nil, errors: state.errors + 1}

    Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{
      agent_id: id,
      msg: error_msg
    })

    Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: id, status: :idle})

    # Reboot the harness (keeps history, resumes via claude_session_id). Queued
    # messages drain onto the fresh CLI inside the restart path — NOT here, so we
    # never drain onto the wedged session we're about to replace.
    {:reboot, state}
  end

  @doc """
  Compute the wait time in milliseconds before retrying after a rate limit.
  Public because ChatAgent.handle_cast(:send_message) also uses it.
  """
  # Re-check at most this often. A weekly (seven_day) limit resets days out;
  # waiting until exactly then is right, but a single multi-day timer is fragile
  # (idle-reap, restart), so cap the poll — without spamming every 60s like before.
  @max_rate_limit_poll_ms 5 * 60 * 1000

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
  Finalize any partial text accumulated from TextDelta events when a
  stream is interrupted (error, timeout, user stop). Persists the
  partial as a truncated assistant message.
  """
  def finalize_partial_on_stream_interrupt(%{in_flight_partial: ""} = state, _id, _reason),
    do: state

  def finalize_partial_on_stream_interrupt(%{in_flight_partial: partial} = state, id, reason)
      when is_binary(partial) and partial != "" do
    marker =
      case reason do
        :error -> "⚠ Truncated — CLI stream errored mid-response."
        :timeout -> "⚠ Truncated — CLI stopped responding mid-stream."
        :stopped_by_user -> "⚠ Truncated — user stopped the agent mid-response."
        other -> "⚠ Truncated — stream ended unexpectedly (#{inspect(other)})."
      end

    partial_msg = %{
      role: :assistant,
      content: partial <> "\n\n" <> marker,
      partial: true,
      timestamp: DateTime.utc_now()
    }

    {state, partial_msg} = append_message(state, partial_msg)
    Persistence.persist_message(state, partial_msg)

    Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{
      agent_id: id,
      msg: partial_msg
    })

    :telemetry.execute(
      [:loopyard, :agent, :partial_finalized],
      %{bytes: byte_size(partial)},
      %{agent_id: id, reason: reason}
    )

    %{state | in_flight_partial: ""}
  end

  def finalize_partial_on_stream_interrupt(state, _id, _reason), do: state

  # --- Private helpers ---

  # Handle a %Event.RateLimitStatus{} from the Claude CLI.
  defp handle_rate_limit_event(state, %Event.RateLimitStatus{} = rl) do
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
            rate_limit_type: rl.rate_limit_type
        }

        :ets.insert(@ets_table, {id, Loopyard.ChatAgent.summary(state)})
        Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: id, status: :rate_limited})

        if first? do
          Loopyard.EventLog.warning(
            "agent:#{state.name}",
            "Rate-limited (#{inspect(rl.rate_limit_type)}); resets #{format_reset(rl.resets_at_ms)}"
          )

          content =
            case rl.rate_limit_type do
              :seven_day ->
                "You've hit your weekly Claude usage limit — resets #{format_reset(rl.resets_at_ms)}. " <>
                  "I'll pick back up automatically when it clears. (For heavy continuous use, " <>
                  "switching the harness to API credits avoids the weekly cap.)"

              other ->
                "Rate-limited (#{other || "limit"}) — I'll resume #{format_reset(rl.resets_at_ms)}."
            end

          rl_msg = %{role: :system, content: content, timestamp: DateTime.utc_now()}
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
            rate_limit_type: rl.rate_limit_type
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
            rate_limit_type: nil
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

  # Handle a %Event.AuthStatus{} from the Claude CLI.
  defp handle_auth_status_event(state, %Event.AuthStatus{error: nil, is_authenticating: true}) do
    state
  end

  defp handle_auth_status_event(state, %Event.AuthStatus{error: error}) when is_binary(error) do
    id = state.id

    :telemetry.execute(
      [:loopyard, :agent, :auth_expired],
      %{count: 1},
      %{agent_id: id, error: error}
    )

    Loopyard.EventLog.error("agent:#{state.name}", "Claude auth failed: #{error}")

    auth_msg = %{
      role: :error,
      content:
        "Claude authentication failed: #{error}. Re-authenticate the CLI and restart this agent.",
      timestamp: DateTime.utc_now()
    }

    {state, auth_msg} =
      append_message(
        %{
          state
          | status: :auth_expired,
            active_tool: nil,
            auth_error: error,
            errors: state.errors + 1
        },
        auth_msg
      )

    Persistence.persist_message(state, auth_msg)
    :ets.insert(@ets_table, {id, Loopyard.ChatAgent.summary(state)})
    Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{agent_id: id, msg: auth_msg})
    Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: id, status: :auth_expired})
    state
  end

  defp handle_auth_status_event(state, _other), do: state

  # Fingerprint a tool call for loop detection.
  defp tool_call_hash(tool_name, tool_input) do
    raw = :erlang.term_to_binary({tool_name, tool_input})
    :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower) |> binary_part(0, 16)
  end

  # Detect same-tool+same-input loops.
  defp maybe_detect_tool_loop(state, id, tool_name, tool_input) do
    hash = tool_call_hash(tool_name, tool_input)

    {new_count, warn?} =
      case state.last_tool_call do
        {^hash, count} when count + 1 == @tool_loop_threshold ->
          {count + 1, true}

        {^hash, count} ->
          {count + 1, false}

        _ ->
          {1, false}
      end

    state = %{state | last_tool_call: {hash, new_count}}

    if warn? do
      :telemetry.execute(
        [:loopyard, :agent, :tool_loop_detected],
        %{consecutive: new_count},
        %{agent_id: id, tool: tool_name}
      )

      Loopyard.EventLog.warning(
        "agent:#{state.name}",
        "Tool-call loop — `#{tool_name}` called #{new_count}× with same input"
      )

      warn_msg = %{
        role: :system,
        content:
          "⚠ Agent called `#{tool_name}` #{new_count} times in a row with the same input — " <>
            "it may be stuck in a retry loop. Consider stopping the agent and providing a " <>
            "different hint, or check whether the tool is returning a consistent error.",
        timestamp: DateTime.utc_now()
      }

      {state, warn_msg} = append_message(state, warn_msg)
      Persistence.persist_message(state, warn_msg)

      Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{
        agent_id: id,
        msg: warn_msg
      })

      state
    else
      state
    end
  end

  # Detect tool-call runaway (too many tool calls in a single turn).
  defp maybe_detect_tool_runaway(%{tool_runaway_warned: true} = state, _id), do: state

  defp maybe_detect_tool_runaway(%{tool_calls_this_turn: n} = state, id)
       when n >= @turn_tool_limit do
    :telemetry.execute(
      [:loopyard, :agent, :tool_runaway],
      %{tool_calls_this_turn: n},
      %{agent_id: id}
    )

    Loopyard.EventLog.warning(
      "agent:#{state.name}",
      "Tool-call runaway — #{n} tool calls in a single turn"
    )

    warn_msg = %{
      role: :system,
      content:
        "⚠ Agent has made #{n} tool calls in this single turn. " <>
          "WHY: that's far past the usual 5–20 — either it's stuck exploring or it's " <>
          "looping with slightly-different inputs each time. " <>
          "CONSEQUENCE: every tool call costs tokens and time. If the agent isn't making " <>
          "visible progress, it's wasting both. " <>
          "ACTION: click Stop to interrupt. Give the agent a more specific hint " <>
          "(e.g. 'the file is in lib/foo.ex') and restart.",
      timestamp: DateTime.utc_now()
    }

    {state, warn_msg} = append_message(state, warn_msg)
    Persistence.persist_message(state, warn_msg)
    Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{agent_id: id, msg: warn_msg})
    %{state | tool_runaway_warned: true}
  end

  defp maybe_detect_tool_runaway(state, _id), do: state

  # Context window sizes for known models.
  defp context_window_for(nil), do: 200_000

  defp context_window_for(model) when is_binary(model) do
    Map.get(@context_windows, model) ||
      Enum.find_value(@context_windows, 0, fn {prefix, size} ->
        if String.starts_with?(model, prefix), do: size
      end)
  end

  defp context_window_for(_), do: 200_000

  # One-shot warning when context utilization crosses the threshold.
  defp maybe_warn_context_full(state, id, utilization)
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

  defp maybe_warn_context_full(state, _id, _utilization), do: state

  # Drain the whole parked flurry at once. Returns `{:drain, list, state}` with
  # the FULL queued list (or `{:noreply, state}` when empty). The caller
  # (ChatAgent.send_batch) shows the individual messages but streams them as ONE
  # framed turn — batched, not one-per-turn, so a flurry queued while
  # rate-limited isn't N separate trips through the limit.
  defp drain_pending_sends(%{pending_sends: []} = state), do: {:noreply, state}

  defp drain_pending_sends(%{pending_sends: pending} = state) do
    {:drain, pending, %{state | pending_sends: []}}
  end

  defp empty_last_response?(state) do
    # Check if the agent produced any visible response this turn.
    # Thinking blocks don't count — the user can't see them unless
    # they expand the collapsed section. If the only output was
    # thinking, the turn looks empty from the user's perspective.
    #
    # state.messages is stored reversed (newest first) for O(1) prepend.
    # Search it directly — Enum.find hits the newest message first.
    last_visible =
      state.messages
      |> Enum.find(fn m -> m.role not in [:thinking, :system] end)

    case last_visible do
      %{role: :user} ->
        # Last visible message is the user's — agent didn't respond at all
        true

      %{role: :assistant, content: c} when is_binary(c) ->
        trimmed = String.trim(c)
        trimmed == "" || trimmed == "(no content)"

      _ ->
        false
    end
  end

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
