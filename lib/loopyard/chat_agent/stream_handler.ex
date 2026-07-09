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

  alias Loopyard.Agent.Event
  alias Loopyard.ChatAgent.{Persistence, SessionManager}
  alias Loopyard.ChatAgent.StreamHandler.RateLimit
  alias Loopyard.Events

  # Rate-limit / auth-status / context-window helpers live in the RateLimit
  # sub-module. Re-expose the ones external callers use so their StreamHandler
  # call sites (ChatAgent, context_panel) stay unchanged.
  defdelegate compute_rate_limit_wait_ms(resets_at_ms), to: RateLimit
  defdelegate format_reset(resets_at_ms), to: RateLimit
  defdelegate rate_limit_label(type), to: RateLimit

  @ets_table :chat_agents

  # Loop-detection threshold: same tool + same input N times in a row.
  @tool_loop_threshold 5

  # Runaway cap: total tool calls in a single turn.
  @turn_tool_limit 50

  # Proactively compact (summarize → fresh session) once a turn ends this far into
  # the window — BEFORE the next turn overflows and wedges. Sits above the warn so
  # the user sees the warning first.
  @context_compact_threshold 0.92

  # Max in-memory messages (matching ChatAgent's cap).
  @max_messages 1000

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

    window = RateLimit.context_window_for(result.model || state.model)

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

    state = RateLimit.maybe_warn_context_full(state, id, utilization)

    # A turn that failed on a transient upstream error (529 / overload /
    # execution error) is flagged here; on_stream_done reads the flag and
    # decides whether to auto-retry. Limit-class failures (max turns/budget)
    # aren't retryable — retrying can't fix them.
    state =
      if result.is_error and retryable_turn_error?(result.error_subtype) do
        %{state | pending_turn_error: result.error_subtype}
      else
        state
      end

    :ets.insert(@ets_table, {id, Loopyard.ChatAgent.summary(state)})
    Persistence.persist_agent(state, &Loopyard.ChatAgent.summary/1)
    Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: id, status: state.status})
    state
  end

  def process_event(%Event.RateLimitStatus{} = rl, state) do
    RateLimit.handle_rate_limit_event(state, rl)
  end

  def process_event(%Event.AuthStatus{} = auth, state) do
    RateLimit.handle_auth_status_event(state, auth)
  end

  def process_event(_other, state), do: state

  # Limit-class failures can't be fixed by retrying; everything else
  # (execution errors, upstream 529/overload, unknown) is transient enough
  # to be worth a bounded retry.
  @non_retryable_turn_errors ~w(error_max_turns error_max_budget_usd error_max_structured_output_retries)
  def retryable_turn_error?(nil), do: false
  def retryable_turn_error?(subtype), do: subtype not in @non_retryable_turn_errors

  # Auto-retry a transient turn failure this many times before giving the
  # message back to the human. DEFAULT 0 — the contract the user wants is
  # "never lose my text": on failure, put it back in the box, don't silently
  # retry. Opt into auto-retry by setting :agent_turn_retries > 0.
  defp max_turn_retries, do: Application.get_env(:loopyard, :agent_turn_retries, 0)

  @doc """
  Handle a stream completion.

    * Turn failed on a transient upstream error (529/overload/execution) with
      retries left → `{:retry_turn, prompt, state}`. OFF by default
      (`:agent_turn_retries` is 0) — opt in only.
    * Failed with no retries → preserve the prompt, surface a clear error, and
      `{:restore_input, prompt, state}` so the UI puts the text back in the box.
      Nothing lost, nothing silently accepted; the human hits Send to retry.
    * Completed normally → `{:drain, list, state}` if parked sends, else
      `{:noreply, state}`.
  """
  def on_stream_done(%{status: status} = state) when status in [:rate_limited, :auth_expired] do
    # A degraded terminal status was set mid-turn (RateLimit rejection / auth
    # error). The turn's stream is now closing, but we must NOT flip back to
    # :idle or drain pending_sends into the limited/expired API — the queue
    # stays parked until the degraded state clears (the rate_limit_retry timer
    # re-arms the turn, or the user re-authenticates). Just preserve any
    # partial text and keep the status.
    state =
      state
      |> finalize_partial_on_stream_interrupt(state.id, :error)
      |> Map.put(:active_tool, nil)

    :ets.insert(@ets_table, {state.id, Loopyard.ChatAgent.summary(state)})
    Persistence.persist_agent(state, &Loopyard.ChatAgent.summary/1)
    {:noreply, state}
  end

  def on_stream_done(state) do
    cond do
      state.pending_turn_error && state.turn_retry_count < max_turn_retries() &&
          is_binary(state.current_turn_prompt) ->
        schedule_turn_retry(state)

      state.pending_turn_error ->
        preserve_failed_turn(state)

      true ->
        complete_turn(state)
    end
  end

  # Auto-retry (opt-in): re-issue the prompt after a backoff with an honest note.
  defp schedule_turn_retry(state) do
    attempt = state.turn_retry_count + 1

    state = %{
      state
      | turn_retry_count: attempt,
        pending_turn_error: nil,
        active_tool: nil,
        in_flight_partial: ""
    }

    msg = %{
      role: :system,
      content:
        "Anthropic's API returned a transient error (their servers, not your " <>
          "message). Retrying (#{attempt}/#{max_turn_retries()})…",
      timestamp: DateTime.utc_now()
    }

    {state, msg} = append_message(state, msg)
    Persistence.persist_message(state, msg)

    Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{
      agent_id: state.id,
      msg: msg
    })

    :ets.insert(@ets_table, {state.id, Loopyard.ChatAgent.summary(state)})

    {:retry_turn, state.current_turn_prompt, state}
  end

  # The turn failed and we're not auto-retrying: DON'T lose the text and DON'T
  # pretend it went through. Surface a clear error, stash the prompt, and tell
  # the caller to put it back in the input box — the human hits Send to retry.
  defp preserve_failed_turn(state) do
    id = state.id
    prompt = state.current_turn_prompt

    err = %{
      role: :error,
      content:
        "Your message didn't go through — Anthropic's API returned an error " <>
          "(their servers, not your code or your message).\n\n" <>
          "Nothing was lost: your text is back in the message box. Hit Send to try " <>
          "again (Anthropic blips are usually brief — status: https://status.claude.com).",
      timestamp: DateTime.utc_now()
    }

    {state, err} = append_message(state, err)
    Persistence.persist_message(state, err)
    Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{agent_id: id, msg: err})

    # Settle to idle WITHOUT draining pending — we're handing the prompt back to
    # the human, not auto-starting another turn.
    state =
      reset_turn_state(%{
        state
        | status: :idle,
          turns: state.turns + 1,
          failed_prompt: prompt,
          errors: state.errors + 1
      })

    :ets.insert(@ets_table, {id, Loopyard.ChatAgent.summary(state)})
    Persistence.persist_agent(state, &Loopyard.ChatAgent.summary/1)
    Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: id, status: :idle})

    if is_binary(prompt), do: {:restore_input, prompt, state}, else: {:noreply, state}
  end

  # The canonical transient-turn reset. Every path that returns the agent to a
  # resting status MUST clear these, or stale turn state leaks into the next
  # turn: a stuck spinner (active_tool), a false "didn't go through" error
  # (pending_turn_error), premature tool-loop/runaway warnings (the tool
  # counters), or a re-fired context warning. Does NOT set :status — the
  # caller picks the resting status.
  defp reset_turn_state(state) do
    %{
      state
      | active_tool: nil,
        in_flight_partial: "",
        pending_turn_error: nil,
        current_turn_prompt: nil,
        turn_retry_count: 0,
        tool_calls_this_turn: 0,
        tool_runaway_warned: false,
        last_tool_call: nil,
        context_warning_sent: false
    }
  end

  defp complete_turn(state) do
    id = state.id

    state = reset_turn_state(%{state | status: :idle, turns: state.turns + 1})
    state = Map.put(state, :consecutive_crashes, 0)

    cond do
      # Proactive compaction: turn finished but we're deep into the window. Compact
      # NOW (summarize → fresh session, no re-send — the turn already answered) so
      # the NEXT turn starts fresh instead of overflowing and wedging. Only when the
      # queue is empty, so we don't delay parked messages (they'll trip it next).
      state.context_utilization >= @context_compact_threshold and state.pending_sends == [] ->
        status_msg = %{
          role: :system,
          content:
            "Compacting context (this session got large — summarizing so it can keep going)…",
          timestamp: DateTime.utc_now()
        }

        {state, status_msg} = append_message(state, status_msg)

        Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{
          agent_id: id,
          msg: status_msg
        })

        :ets.insert(@ets_table, {id, Loopyard.ChatAgent.summary(state)})
        Persistence.persist_agent(state, &Loopyard.ChatAgent.summary/1)
        {:auto_restart_context, nil, state}

      # Recovery: context overflowed so hard the model returned NOTHING — compact
      # AND re-send the user's message so they still get an answer.
      state.context_utilization >= 1.0 && empty_last_response?(state) ->
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

      true ->
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

    # Count recent auto-restarts (within last 60 seconds) so a deterministically
    # dying CLI doesn't hot-loop. This must match the marker actually written
    # below ("Agent session restarted automatically…") — the previous literal
    # ("Agent crashed — restarting...") was never emitted anywhere, so the
    # breaker was dead and the loop ran with zero backoff.
    recent_crashes =
      state.messages
      |> Enum.count(fn m ->
        m.role == :system && is_binary(m.content) &&
          String.starts_with?(m.content, "Agent session restarted automatically") &&
          DateTime.diff(now, m.timestamp, :second) < 60
      end)

    if is_binary(reason) && String.contains?(reason, "CLI session exited") && recent_crashes < 2 do
      # CLI died — restart session and resume the same conversation
      state = %{state | last_activity_at: now, errors: state.errors + 1}

      case state.backend.start_session(SessionManager.start_opts(state)) do
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
          state = reset_turn_state(%{state | status: :idle})

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

      state = reset_turn_state(%{state | status: :idle, last_activity_at: now, errors: state.errors + 1})

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
      content: "CLI went unresponsive — auto-restarted, history kept.",
      timestamp: DateTime.utc_now()
    }

    {state, error_msg} = append_message(state, error_msg)

    # Clear stream_ref along with the turn transients: the wedged stream Task
    # may still be alive, and dropping its ref means any late events it emits
    # are ignored instead of mutating a now-"idle" agent (matters if the
    # reboot below fails and leaves us resting).
    state = reset_turn_state(%{state | status: :idle, errors: state.errors + 1, stream_ref: nil})

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
