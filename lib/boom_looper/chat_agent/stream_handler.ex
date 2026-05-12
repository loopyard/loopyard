defmodule BoomLooper.ChatAgent.StreamHandler do
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

  alias BoomLooper.Agent.Event
  alias BoomLooper.ChatAgent.{Persistence, SessionManager}
  alias BoomLooper.Events

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
    Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{agent_id: state.id, msg: msg})
    state
  end

  def process_event(%Event.ThinkingDelta{thinking: thinking}, state) do
    # Stream thinking deltas to the UI for live display
    Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.TextDelta{
      agent_id: state.id,
      text: ""
    })

    %{state | in_flight_partial: state.in_flight_partial <> (thinking || "")}
  end

  def process_event(%Event.ServerTool{name: name, input: input}, state) do
    now = DateTime.utc_now()
    msg = %{role: :tool, tool: "server__#{name}", input: input, timestamp: now}
    {state, msg} = append_message(state, msg)
    Persistence.persist_message(state, msg)
    Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{agent_id: state.id, msg: msg})
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

    :ets.insert(@ets_table, {id, BoomLooper.ChatAgent.summary(state)})
    Persistence.persist_agent(state, &BoomLooper.ChatAgent.summary/1)
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

      :ets.insert(@ets_table, {id, BoomLooper.ChatAgent.summary(state)})
      Persistence.persist_agent(state, &BoomLooper.ChatAgent.summary/1)

      {:auto_restart_context, last_user_msg && last_user_msg.content, state}
    else
      :ets.insert(@ets_table, {id, BoomLooper.ChatAgent.summary(state)})
      Persistence.persist_agent(state, &BoomLooper.ChatAgent.summary/1)
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

    BoomLooper.EventLog.error("agent:#{state.name}", "Stream error: #{reason}")

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
                "ACTION: click Restart in the sidebar. If that also fails, the Claude CLI " <>
                "may be misconfigured — verify `claude --version` and re-authenticate.",
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

    BoomLooper.EventLog.warning("agent:#{state.name}", "Stream timed out, resetting to idle")

    # Finalize any partial text the stream produced before the timeout
    state = finalize_partial_on_stream_interrupt(state, id, :timeout)

    error_msg = %{
      role: :error,
      content:
        "Agent stopped responding after 10 minutes. " <>
          "WHY: the streaming task produced no events within the timeout window — usually a tool " <>
          "call (exec, rebuild, compose up) hung, or the CLI deadlocked. " <>
          "CONSEQUENCE: the turn was dropped; any partial assistant text was preserved. " <>
          "ACTION: send another message to retry. If the same tool keeps wedging, check " <>
          "/system/events for the tool name and diagnose it in isolation.",
      timestamp: DateTime.utc_now()
    }

    {state, error_msg} = append_message(state, error_msg)
    state = %{state | status: :idle, active_tool: nil, errors: state.errors + 1}

    Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{
      agent_id: id,
      msg: error_msg
    })

    Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: id, status: :idle})
    drain_pending_sends(state)
  end

  @doc """
  Compute the wait time in milliseconds before retrying after a rate limit.
  Public because ChatAgent.handle_cast(:send_message) also uses it.
  """
  def compute_rate_limit_wait_ms(resets_at_ms) when is_integer(resets_at_ms) do
    now_ms = System.system_time(:millisecond)
    delta = resets_at_ms - now_ms

    cond do
      delta <= 0 -> 60_000
      delta > 3_600_000 -> 60_000
      true -> delta + 1_000
    end
  end

  def compute_rate_limit_wait_ms(_), do: 60_000

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
      [:boom_looper, :agent, :partial_finalized],
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
      [:boom_looper, :agent, :rate_limit],
      %{count: 1},
      %{agent_id: id, status: rl.status, rate_limit_type: rl.rate_limit_type}
    )

    case rl.status do
      :rejected ->
        wait_ms = compute_rate_limit_wait_ms(rl.resets_at_ms)

        BoomLooper.EventLog.warning(
          "agent:#{state.name}",
          "Rate-limited (#{inspect(rl.rate_limit_type)}), retrying in #{div(wait_ms, 1000)}s"
        )

        Process.send_after(self(), {:rate_limit_retry, id}, wait_ms)

        rl_msg = %{
          role: :system,
          content:
            "Rate-limited by Claude API (#{rl.rate_limit_type || "limit"}). " <>
              "Retrying automatically in ~#{div(wait_ms, 1000)}s.",
          timestamp: DateTime.utc_now()
        }

        {state, rl_msg} =
          append_message(
            %{
              state
              | status: :rate_limited,
                active_tool: nil,
                rate_limit_status: :rejected,
                rate_limit_resets_at_ms: rl.resets_at_ms,
                rate_limit_type: rl.rate_limit_type
            },
            rl_msg
          )

        Persistence.persist_message(state, rl_msg)
        :ets.insert(@ets_table, {id, BoomLooper.ChatAgent.summary(state)})

        Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{
          agent_id: id,
          msg: rl_msg
        })

        Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: id, status: :rate_limited})
        state

      :allowed_warning ->
        state = %{
          state
          | rate_limit_status: :warning,
            rate_limit_resets_at_ms: rl.resets_at_ms,
            rate_limit_type: rl.rate_limit_type
        }

        :ets.insert(@ets_table, {id, BoomLooper.ChatAgent.summary(state)})
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

        :ets.insert(@ets_table, {id, BoomLooper.ChatAgent.summary(state)})

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
      [:boom_looper, :agent, :auth_expired],
      %{count: 1},
      %{agent_id: id, error: error}
    )

    BoomLooper.EventLog.error("agent:#{state.name}", "Claude auth failed: #{error}")

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
    :ets.insert(@ets_table, {id, BoomLooper.ChatAgent.summary(state)})
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
        [:boom_looper, :agent, :tool_loop_detected],
        %{consecutive: new_count},
        %{agent_id: id, tool: tool_name}
      )

      BoomLooper.EventLog.warning(
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
      [:boom_looper, :agent, :tool_runaway],
      %{tool_calls_this_turn: n},
      %{agent_id: id}
    )

    BoomLooper.EventLog.warning(
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
        [:boom_looper, :agent, :context_warning],
        %{utilization: utilization},
        %{agent_id: id, model: state.model}
      )

      BoomLooper.EventLog.warning(
        "agent:#{state.name}",
        "Context window #{pct}% full (model=#{state.model || "?"})"
      )

      %{state | context_warning_sent: true}
    end
  end

  defp maybe_warn_context_full(state, _id, _utilization), do: state

  # Drain the pending-sends queue. Returns `{:drain, text, state}` when
  # there's a message to send, or `{:noreply, state}` when empty. The
  # caller (ChatAgent) handles the actual `send_message_normal` dispatch.
  defp drain_pending_sends(%{pending_sends: []} = state), do: {:noreply, state}

  defp drain_pending_sends(%{pending_sends: [head | rest]} = state) do
    {:drain, head, %{state | pending_sends: rest}}
  end

  defp empty_last_response?(state) do
    case List.last(state.messages) do
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
