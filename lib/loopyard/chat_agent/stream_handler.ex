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

  Cohesive clusters live in sub-modules, re-exposed here so call sites
  are unchanged: rate-limit/auth/context-window in `RateLimit`,
  tool-loop/runaway detection in `LoopGuard`, error/timeout recovery in
  `Recovery`. Message appends go through the shared
  `Loopyard.ChatAgent.MessageLog`.
  """

  alias Loopyard.Agent.Event
  alias Loopyard.ChatAgent.{MessageLog, Persistence}
  alias Loopyard.ChatAgent.StreamHandler.{LoopGuard, RateLimit, Recovery}
  alias Loopyard.Events

  # Rate-limit / auth-status / context-window helpers live in the RateLimit
  # sub-module. Re-expose the ones external callers use so their StreamHandler
  # call sites (ChatAgent, context_panel) stay unchanged.
  defdelegate compute_rate_limit_wait_ms(resets_at_ms), to: RateLimit
  defdelegate format_reset(resets_at_ms), to: RateLimit
  defdelegate rate_limit_label(type), to: RateLimit

  # Error/timeout recovery lives in the Recovery sub-module; ChatAgent's call
  # sites keep saying StreamHandler.
  defdelegate on_stream_error(state, reason), to: Recovery
  defdelegate on_stream_timeout(state), to: Recovery
  defdelegate finalize_partial_on_stream_interrupt(state, id, reason), to: Recovery

  @ets_table :chat_agents

  # Proactively compact (summarize → fresh session) once a turn ends this far into
  # the window — BEFORE the next turn overflows and wedges. Sits above the warn so
  # the user sees the warning first.
  @context_compact_threshold 0.92

  # Streaming-delta publish cadence. Raw token deltas queue in
  # state.stream_pub_buffer and one combined publish per channel goes out
  # each tick — 10 DOM patches/s per viewer instead of one per token.
  # 100ms is imperceptible for reading a live stream but keeps heavy
  # streams from monopolizing the browser main thread (typing lag).
  @delta_flush_ms 100

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
    # subsequent stream_error/timeout doesn't re-emit it. Unflushed delta
    # chunks are dropped too: the Message below supersedes them, and a
    # late flush after it would resurrect a ghost streaming bubble.
    state = drop_stream_deltas(%{state | last_activity_at: now, in_flight_partial: ""})
    Persistence.persist_message(state, assistant_msg)

    Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{
      agent_id: id,
      msg: assistant_msg
    })

    state
  end

  def process_event(%Event.ToolCall{name: tool_name, input: tool_input} = ev, state) do
    now = DateTime.utc_now()
    id = state.id
    # Neutral tool kind travels ON the message so the UI classifies by kind,
    # never by matching raw tool names. A backend may set ev.kind itself; else
    # we derive it from the name via the single ToolKind seam.
    tool_kind = ev.kind || Loopyard.Agent.ToolKind.classify(tool_name)

    tool_msg = %{
      role: :tool,
      tool: tool_name,
      tool_kind: tool_kind,
      tool_id: ev.id,
      input: tool_input,
      timestamp: now
    }

    {state, tool_msg} = append_message(state, tool_msg)

    state = %{
      state
      | last_activity_at: now,
        tool_calls: state.tool_calls + 1,
        active_tool: tool_name,
        tool_calls_this_turn: state.tool_calls_this_turn + 1
    }

    # Loop detection: same tool + same input N times in a row
    state = LoopGuard.maybe_detect_tool_loop(state, id, tool_name, tool_input)

    # Runaway cap: even if individual calls differ, a 50+ tool-call
    # turn is almost always the agent flailing. Warn once.
    state = LoopGuard.maybe_detect_tool_runaway(state, id)

    Persistence.persist_message(state, tool_msg)
    Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{agent_id: id, msg: tool_msg})
    # Feed the global/per-project activity stream (#54): this is the "latest
    # tool call" the god-mode sidebar surfaces across all projects.
    Loopyard.Events.Activity.record(id, :tool, tool_name)
    state
  end

  def process_event(%Event.ToolResult{id: tool_id, content: content, is_error: is_error}, state) do
    now = DateTime.utc_now()
    id = state.id
    # tool_id pairs this result with its %{role: :tool} message. Tool calls can
    # run in PARALLEL (all calls emitted, then all results), so "the message
    # above me" is NOT reliably my call — the UI pairs by id, never position.
    result_msg = %{
      role: :tool_result,
      tool_id: tool_id,
      content: content,
      is_error: is_error,
      timestamp: now
    }

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
    # Don't publish per token — queue the chunk; the :flush_stream_deltas
    # timer publishes one combined TextDelta per @delta_flush_ms. Per-token
    # publishes made every viewer re-patch the whole streamed text 30–60×/s,
    # lagging keyboard input browser-side.
    state = %{state | in_flight_partial: state.in_flight_partial <> (text || "")}
    buffer_stream_delta(state, :text, text || "")
  end

  def process_event(%Event.Thinking{thinking: thinking}, state) do
    now = DateTime.utc_now()
    # Finalized thinking block supersedes any queued thinking chunks.
    state = drop_stream_deltas(state)
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
    # Separate channel from response text (LV streams it into its own
    # assign); same coalescing as TextDelta — see buffer_stream_delta/3.
    buffer_stream_delta(state, :thinking, thinking || "")
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
    # aren't retryable — retrying can't fix them. AUTH failures aren't either:
    # "Authentication required" once burned all 3 retries as if transient —
    # route it to the auth-expired flow (status + banner + credential-resourcing
    # self-heal) instead, which is the thing that can actually fix it.
    state =
      cond do
        result.is_error and auth_error?(result.error_subtype) ->
          RateLimit.handle_auth_status_event(state, %Event.AuthStatus{
            error: to_string(result.error_subtype)
          })

        result.is_error and retryable_turn_error?(result.error_subtype) ->
          %{state | pending_turn_error: result.error_subtype}

        true ->
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

  @doc false
  def auth_error?(subtype) when is_binary(subtype) do
    down = String.downcase(subtype)

    Enum.any?(
      ["authentication", "unauthorized", "401", "not logged in", "oauth", "invalid api key"],
      &String.contains?(down, &1)
    )
  end

  def auth_error?(_), do: false
  def retryable_turn_error?(nil), do: false
  def retryable_turn_error?(subtype), do: subtype not in @non_retryable_turn_errors

  # Auto-retry a transient turn failure this many times before giving the
  # message back to the human. DEFAULT 3 — the SYSTEM is the retry loop, never
  # the human ("Turn failed — tap Send to retry" made the user redo what the
  # machine should have; Brad called it "a level of indirection"). The text is
  # never lost either way: retries re-drive the SAME prompt, and the final
  # give-up still hands it back to the box. Set :agent_turn_retries 0 to opt
  # out (tests do, to exercise the give-up path deterministically).
  defp max_turn_retries, do: Application.get_env(:loopyard, :agent_turn_retries, 3)

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
    # Degraded status set mid-turn (rate-limit rejection / auth error): keep it
    # and DON'T drain pending_sends into the limited/expired API. The queue
    # stays parked until the degraded state clears; just preserve partial text.
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

  # Auto-retry: re-issue the prompt after a backoff — SILENTLY. The system is
  # fixing it; a chat line about self-healing is noise ("it either broke or it
  # didn't"). EventLog carries the detail; the thinking indicator covers the
  # visible pause.
  defp schedule_turn_retry(state) do
    attempt = state.turn_retry_count + 1
    reason = state.pending_turn_error

    state = %{
      drop_stream_deltas(state)
      | turn_retry_count: attempt,
        pending_turn_error: nil,
        active_tool: nil,
        in_flight_partial: ""
    }

    Loopyard.EventLog.warning(
      "agent:#{state.name}",
      "transient turn error (#{inspect(reason)}) — retry #{attempt}/#{max_turn_retries()}"
    )

    :ets.insert(@ets_table, {state.id, Loopyard.ChatAgent.summary(state)})

    {:retry_turn, state.current_turn_prompt, state}
  end

  # The turn failed and retries are exhausted. RECOVERY NEVER TOUCHES THE
  # COMPOSER — the input box is for humans only (a machine-built resume seed
  # once got "restored" into it, dumping the whole chat history at the user).
  # A failed HUMAN turn: the message is already in the transcript; say why it
  # went unanswered. A failed SEED turn: EventLog only — its prompt is
  # regenerable machinery, not something to surface.
  defp preserve_failed_turn(%{current_turn_origin: :seed} = state) do
    id = state.id

    Loopyard.EventLog.error(
      "agent:#{state.name}",
      "seed/continuation turn failed (#{inspect(state.pending_turn_error)}) — going idle"
    )

    state =
      reset_turn_state(%{state | status: :idle, turns: state.turns + 1, errors: state.errors + 1})

    :ets.insert(@ets_table, {id, Loopyard.ChatAgent.summary(state)})
    Persistence.persist_agent(state, &Loopyard.ChatAgent.summary/1)
    Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: id, status: :idle})
    {:noreply, state}
  end

  defp preserve_failed_turn(state) do
    id = state.id
    prompt = state.current_turn_prompt

    # WHY / CONSEQUENCE / ACTION — never a bare "turn failed" (that's a level
    # of indirection: the system already retried; say what actually happened
    # and what the human's one remaining move is).
    attempts = max_turn_retries()

    retried = if attempts > 0, do: " after #{attempts} automatic retries", else: ""

    err = %{
      role: :error,
      content:
        "This didn't go through — Anthropic's API failed#{retried} " <>
          "(#{inspect(state.pending_turn_error)}). Send it again.",
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

    {:noreply, state}
  end

  # Canonical transient-turn reset. Every path back to a resting status MUST
  # clear these, or stale turn state leaks into the next turn (stuck spinner,
  # false "didn't go through" error, premature loop warnings, re-fired context
  # warning). Does NOT set :status — the caller picks the resting status.
  # Public (@doc false) so the Recovery sub-module reuses the ONE canonical
  # reset; not part of the API surface.
  @doc false
  def reset_turn_state(state) do
    %{
      drop_stream_deltas(state)
      | active_tool: nil,
        in_flight_partial: "",
        pending_turn_error: nil,
        current_turn_prompt: nil,
        current_turn_origin: :human,
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
    # Clean completion → the harness survived this conversation size; the
    # compact-instead-of-resume breaker starts over.
    state = Map.put(state, :midturn_crashes, 0)
    # A turn completed cleanly → credentials are valid; clear the auth backoff so
    # the next failure (if any) starts fresh rather than at a capped interval.
    state = Map.put(state, :auth_retry_count, 0)
    # A completed turn PROVES the credential — this is the one place the auth
    # flag clears (restarts only re-source, they don't prove). Flipping the
    # flag also flips any pending auth-fix card GREEN in place — the mini-app's
    # "I did the thing and saw it work" receipt.
    state =
      if is_binary(state.auth_error) do
        resolve_auth_fix_cards(%{state | auth_error: nil})
      else
        state
      end

    cond do
      # Recovery FIRST (order matters): context overflowed so hard the model
      # returned NOTHING — compact AND re-send the user's message so they still
      # get an answer. This must be checked BEFORE the proactive compact below:
      # >= 1.0 also satisfies >= @context_compact_threshold, and with an empty
      # queue the proactive branch would swallow this case with a nil re-send —
      # the user's overflowed message would silently never be answered.
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
  Publish everything queued in `state.stream_pub_buffer` — one combined
  event per channel run, in arrival order — and rearm for the next tick.
  Called from ChatAgent's `:flush_stream_deltas` timer. No-op (beyond
  clearing the timer ref) when the buffer is empty or the turn is no
  longer streaming.
  """
  # These three helpers use Map.get/Map.put (not strict struct access) on the
  # two coalescing fields: agents live through hot code reloads on a running
  # dev server, and a GenServer holding a pre-reload struct (without the new
  # keys) must not KeyError mid-stream.
  def flush_stream_deltas(state) do
    buffer = Map.get(state, :stream_pub_buffer, [])
    id = state.id

    # Publish only while the turn is still streaming — after an interrupt
    # that raced the timer, the finalized Message already superseded these
    # chunks, and publishing them would corrupt the next turn's assigns.
    if buffer != [] and state.status == :thinking do
      buffer
      |> Enum.reverse()
      |> Enum.each(fn
        {:text, text} ->
          Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.TextDelta{
            agent_id: id,
            text: text
          })

        {:thinking, data} ->
          Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.StreamOutput{
            agent_id: id,
            data: data,
            title: "__thinking__",
            msg_id: "__thinking__"
          })
      end)
    end

    state |> Map.put(:stream_pub_buffer, []) |> Map.put(:stream_pub_timer, nil)
  end

  @doc """
  Discard queued delta chunks and cancel the pending flush tick. Every path
  that finalizes or resets a turn goes through this — see the struct docs
  on `stream_pub_buffer`.
  """
  def drop_stream_deltas(state) do
    if timer = Map.get(state, :stream_pub_timer), do: Process.cancel_timer(timer)
    state |> Map.put(:stream_pub_buffer, []) |> Map.put(:stream_pub_timer, nil)
  end

  # Drain the whole parked flurry at once. Returns `{:drain, list, state}` with
  # the FULL queued list (or `{:noreply, state}` when empty). The caller
  # (ChatAgent.send_batch) shows the individual messages but streams them as ONE
  # framed turn — batched, not one-per-turn, so a flurry queued while
  # rate-limited isn't N separate trips through the limit.
  # Public (@doc false) so the Recovery sub-module reuses it; not API surface.
  @doc false
  def drain_pending_sends(%{pending_sends: []} = state), do: {:noreply, state}

  def drain_pending_sends(%{pending_sends: pending} = state) do
    {:drain, pending, %{state | pending_sends: []}}
  end

  # --- Private helpers ---

  # Queue a streaming chunk for the next flush tick, coalescing onto the
  # newest chunk when the channel matches (buffer is stored reversed).
  # Arms the flush timer if idle.
  defp buffer_stream_delta(state, _channel, ""), do: state

  defp buffer_stream_delta(state, channel, text) do
    buffer =
      case Map.get(state, :stream_pub_buffer, []) do
        [{^channel, acc} | rest] -> [{channel, acc <> text} | rest]
        other -> [{channel, text} | other]
      end

    timer =
      Map.get(state, :stream_pub_timer) ||
        Process.send_after(self(), :flush_stream_deltas, @delta_flush_ms)

    state |> Map.put(:stream_pub_buffer, buffer) |> Map.put(:stream_pub_timer, timer)
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

  # Append via the ONE shared MessageLog (id assignment + message cap).
  defp append_message(state, msg), do: MessageLog.append(state, msg)

  # Flip every pending auth-fix card to :resolved + broadcast the update, so
  # the card the user acted on turns green for every viewer.
  defp resolve_auth_fix_cards(state) do
    {messages, flipped} =
      Enum.map_reduce(state.messages, [], fn msg, acc ->
        if msg[:role] == :auth_fix and msg[:status] == :pending do
          msg = Map.put(msg, :status, :resolved)
          {msg, [msg | acc]}
        else
          {msg, acc}
        end
      end)

    state = %{state | messages: messages}

    Enum.each(flipped, fn msg ->
      Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.MessageUpdated{
        agent_id: state.id,
        msg: msg
      })
    end)

    state
  end
end
