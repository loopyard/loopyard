defmodule Loopyard.ChatAgent.Restart do
  @moduledoc """
  The session-restart helper cluster for `Loopyard.ChatAgent`: the actual
  restart-now path (`restart_session_now/2`) plus the crash-interrupted-turn
  helpers the `:restart_session` breaker gate consults.

  Same contract as the other ChatAgent helper modules: functions take the
  agent's state and run IN the agent's process (they `self()`-cast /
  `Process.send_after(self(), …)`), returning the `{:noreply, state}` shape
  the `handle_cast` caller returns as-is. The GenServer callbacks stay in
  ChatAgent.
  """

  alias Loopyard.ChatAgent.{Initializer, MessageLog, SessionManager}
  alias Loopyard.Events

  @ets_table :chat_agents

  # Mirrors ChatAgent's @max_consecutive_crashes — the point at which the
  # retry machinery stops trying, which is exactly when a human needs telling.
  defp max_crashes, do: Application.get_env(:loopyard, :max_consecutive_crashes, 5)

  # The chat marker for a session restart, or nil for silence. Only events the
  # user should KNOW about earn a line: a real crash recovery, or their own
  # Restart click (confirmation). Maintenance reasons are EventLog-only.
  # `resumed?` — did we actually resume the prior harness session, or start fresh
  # and rebuild context from Loopyard's durable log? A non-nil live_id does NOT
  # mean "resumed" (session/new returns a fresh id too), so the copy keys off
  # resumed?, never off the id.
  # Successful crash recovery is SILENT (EventLog carries the details): the
  # user is told only when recovery fails or keeps failing — "it worked" is
  # not news (Brad, twice). The user's own Restart click still confirms.
  defp restart_note(:recovery, _resumed?, _live_id), do: nil

  defp restart_note(:user, true, _), do: "Session restarted (conversation resumed)."
  defp restart_note(:user, false, _), do: "Session restarted; rebuilding context from history."

  defp restart_note(:reload, true, _),
    do: "Restarted — tools reloaded, conversation resumed."

  defp restart_note(:reload, false, _),
    do: "Restarted — tools reloaded, rebuilding context from history."

  defp restart_note(_maintenance, _resumed?, _live_id), do: nil

  # The user's last message with NO assistant reply after it — the in-flight
  # turn a mid-turn crash interrupted. nil when the last turn already completed
  # (nothing to re-run) OR when we've compacted repeatedly in a short window (a
  # fresh session that keeps crashing too — stop auto-retrying, let the user see
  # it's stuck rather than spin forever).
  def pending_user_prompt(state) do
    if compaction_looping?(state) do
      nil
    else
      Enum.reduce_while(Enum.reverse(state.messages || []), nil, fn m, _ ->
        cond do
          m[:role] == :assistant ->
            {:halt, nil}

          m[:role] == :user and is_binary(m[:content]) and m[:content] != "" ->
            {:halt, m[:content]}

          true ->
            {:cont, nil}
        end
      end)
    end
  end

  # ≥3 compactions in 3 minutes = even fresh sessions keep dying, so the problem
  # isn't the resumed history — don't auto-retry into an infinite loop.
  defp compaction_looping?(state) do
    now = DateTime.utc_now()

    Enum.count(state.messages || [], fn m ->
      m[:role] == :system and is_binary(m[:content]) and
        String.contains?(m[:content], "Compacting instead") and
        match?(%DateTime{}, m[:timestamp]) and DateTime.diff(now, m[:timestamp], :second) < 180
    end) >= 3
  end

  def restart_session_now(state, reason) do
    # A full ("reload tools") restart rebuilds session_opts from the agent's boot
    # opts BEFORE restarting, so the fresh CLI picks up a changed MCP tool set +
    # a system prompt re-read from disk. Falls back to the frozen opts if the
    # rebuild fails (e.g. workspace config momentarily unreadable) — the button
    # still recovers a wedged harness. Everything downstream is the normal
    # restart, so the conversation resumes just like `:user`.
    state =
      if reason == :reload do
        case Initializer.rebuild_session_opts(state) do
          {:ok, fresh_opts, prompt_hash} ->
            %{state | session_opts: fresh_opts, prompt_hash: prompt_hash}

          {:error, _} ->
            state
        end
      else
        state
      end

    # A credential/account switch invalidates the native session id — the NEW
    # account can't resume the old session, so resuming would boot the agent
    # amnesic ("switched accounts and it forgot everything"). Drop it → start
    # fresh and reconstruct from Loopyard's durable log (the seed below + the
    # recall_conversation tool). Every other reason keeps the id and resumes.
    state = if reason == :credentials, do: %{state | claude_session_id: nil}, else: state

    # Stop the current session
    if state.session do
      # Wrap backend.stop in a Task + Task.yield with timeout so a
      # hung CLI stop doesn't block the GenServer indefinitely. Also
      # wrap in try/catch so a raise inside backend.stop (or a crashed
      # Task) doesn't take down the caller — Task.yield EXITS the
      # caller with the task's exit reason if the task crashes.
      SessionManager.stop_backend(state.session, state.backend)
    end

    # Start a fresh session with the same opts. When we have a Claude
    # session_id captured from prior turns, pass it as `resume:` so the
    # CLI picks up the same conversation.
    prior_sid = state.claude_session_id

    case SessionManager.start_session_safe(state) do
      {:ok, new_session, live_id} ->
        # Did we actually RESUME prior context, or start fresh? Fresh = we passed
        # no resume id (a credential switch nulled it above, or first boot) OR we
        # passed one but the adapter fell back to session/new (oversized/expired
        # resume). Either way the session's context is EMPTY and must be re-seeded;
        # a non-nil live_id does NOT imply "has history" (session/new returns a
        # fresh id too — that was the amnesia bug: the old gate seeded only when
        # live_id was nil, so a fresh-but-id'd session booted empty).
        resumed? = is_binary(prior_sid) and live_id == prior_sid

        # A reboot is a full reset-to-idle — clear EVERY piece of transient turn
        # state, or the agent looks idle while the stream machinery thinks a turn
        # is live (stale stream_ref), and the next send is silently swallowed.
        # `claude_session_id: live_id` ADOPTS the harness's real current id — if a
        # stale/oversized resume failed and the connection fell back to a fresh
        # session/new, we track the new id instead of re-resuming the dead one.
        state =
          SessionManager.track_os_pid(%{
            state
            | session: new_session,
              claude_session_id: live_id,
              status: :idle,
              stream_ref: nil,
              active_tool: nil,
              in_flight_partial: "",
              tool_calls_this_turn: 0,
              tool_runaway_warned: false,
              last_tool_call: nil,
              context_warning_sent: false,
              # auth_error clears ONLY on a :credentials restart — the moment a
              # human pushed a fresh token. Every other reason leaves it: a
              # restart re-sources credentials, it doesn't prove them, and
              # clearing optimistically made the fleet-outage signal (and the
              # operator's token mini-app) FLAP between self-heal cycles. That
              # flapping was about AUTOMATIC restarts; a credential reload is a
              # deliberate human act, so treating it as evidence doesn't loop.
              #
              # Without this the agent sat at :idle with a valid token while the
              # sidebar read "Sign-in expired" indefinitely — the auth card
              # promises "everything resumes on its own once the token lands,
              # this card turns green" and it never did, because only a
              # completed turn cleared the flag. A bad token just re-sets it on
              # the next turn, which is the correct cost.
              auth_error: if(reason == :credentials, do: nil, else: state.auth_error)
          })

        :ets.insert(@ets_table, {state.id, Loopyard.ChatAgent.summary(state)})
        Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: state.id, status: :idle})

        # What the CHAT says depends on WHY we restarted. Deliberate
        # maintenance (credential reload, memory reclaim) on a healthy agent
        # is SILENT — announcing "CLI crashed" for every token push made an
        # idle agent look broken. Those reasons go to the EventLog only; the
        # harness-status sidebar block already covers the in-between state.
        state =
          case restart_note(reason, resumed?, live_id) do
            nil ->
              Loopyard.EventLog.info(
                "agent:#{state.name}",
                "Session restarted (#{reason}), " <>
                  if(resumed?,
                    do: "resumed #{String.slice(live_id, 0..7)}…",
                    else: "rebuilt context from history"
                  )
              )

              state

            note ->
              restart_msg = %{role: :system, content: note, timestamp: DateTime.utc_now()}
              {state, restart_msg} = MessageLog.append(state, restart_msg)

              Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{
                agent_id: state.id,
                msg: restart_msg
              })

              state
          end

        # Started fresh (switch, first boot, or a resume that fell back to
        # session/new) → seed the empty session with recent context verbatim so
        # the model isn't amnesic; the rest is a recall_conversation call away.
        # A genuinely resumed session already has its history.
        unless resumed? do
          if seed = Loopyard.ChatAgent.ResumeMessage.build(state.messages) do
            GenServer.cast(self(), {:resume_prompt, seed})
          end
        end

        # Drain a message the user queued while the harness was wedged onto the
        # fresh CLI (one at a time — the rest pop on turn completion, which
        # batches). NOT batched here: if the backend is permanently dead, this
        # recovery path loops, and batching would nest the queue exponentially.
        #
        # DELAYED, not immediate: right after session/load the adapter's
        # underlying CLI subprocess can still be spinning up — prompting in
        # that window dies with "ProcessTransport is not ready for writing"
        # (observed with claude-code-acp 0.16.2 on large-session resumes). A
        # few seconds of settle time lets the resumed subprocess become
        # writable before the queued send hits it. Reuses the existing
        # :drain_resumed_pending handler (batch-drains only when :idle).
        if state.pending_sends != [] do
          settle_ms = Application.get_env(:loopyard, :pending_drain_settle_ms, 4_000)
          Process.send_after(self(), :drain_resumed_pending, settle_ms)
        end

        {:noreply, state}

      {:error, reason, next_hint} ->
        # DON'T give up — a spawn failure is often transient (docker exec racing
        # a container restart, a config file mid-rewrite, a momentary API blip).
        # Schedule a backoff retry through the existing :retry_session machinery;
        # the crash-loop breaker (@max_consecutive_crashes) still bounds it.
        # ADOPT next_hint: one-strike resume — if this failure was a resume, the
        # hint is now nil so the retry is a guaranteed-fresh session/new.
        state = %{state | claude_session_id: next_hint}
        consecutive = Map.get(state, :consecutive_crashes, 0) + 1
        base = Application.get_env(:loopyard, :crash_backoff_base_ms, 2_000)
        backoff_ms = Loopyard.Retry.backoff_ms(consecutive, {:exponential, base})
        Process.send_after(self(), {:retry_session, consecutive, state.session}, backoff_ms)

        # SILENCE WHILE SELF-HEALING. We just scheduled a retry, so by the
        # project's own rule (CLAUDE.md → "Errors speak ONLY when the user can
        # act and the system can't self-fix") this earns no chat line: the
        # EventLog records it and the harness-status block shows "Reconnecting".
        #
        # It used to post a red wall whose own text said "ACTION: none —
        # retrying automatically", which is the definition of noise — and worse,
        # a chat message is PERMANENT. The retry would succeed seconds later and
        # the transcript kept a crash report forever, so a perfectly healthy
        # agent read as horribly broken every time you scrolled past it.
        #
        # The message is earned only when self-healing has actually given up:
        # at that point no more retries are coming and a human has to act.
        giving_up? = consecutive >= max_crashes()

        Loopyard.EventLog.warning(
          "agent:#{state.name}",
          "Session restart failed (#{inspect(reason)}); retry #{consecutive} in #{div(backoff_ms, 1000)}s"
        )

        state =
          %{state | errors: state.errors + 1, status: :backoff}
          |> Map.put(:consecutive_crashes, consecutive)
          |> Map.put(:retry_from_session, state.session)

        state =
          if giving_up? do
            error_msg = %{
              role: :error,
              content:
                "The agent harness won't start (#{inspect(reason)}) after #{consecutive} attempts. " <>
                  "CONSEQUENCE: no turn can run; every message you've sent is preserved. " <>
                  "ACTION: check the harness in the container, then click Restart.",
              timestamp: DateTime.utc_now()
            }

            {state, error_msg} = MessageLog.append(state, error_msg)

            Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{
              agent_id: state.id,
              msg: error_msg
            })

            state
          else
            state
          end

        :ets.insert(@ets_table, {state.id, Loopyard.ChatAgent.summary(state)})
        Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: state.id, status: :backoff})

        {:noreply, state}
    end
  end
end
