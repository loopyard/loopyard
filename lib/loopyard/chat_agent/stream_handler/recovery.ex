defmodule Loopyard.ChatAgent.StreamHandler.Recovery do
  @moduledoc """
  Stream error/timeout recovery for the streaming turn: CLI-death
  restart-or-compact, the unrecoverable-error path, the stall-watchdog
  reboot, and partial-text finalization on any interrupt.

  Extracted from `StreamHandler`; same contract — functions take state
  and return state (or the `{:drain, list, state}` / `{:noreply, state}`
  / `{:build_resume, state}` / `{:reboot, state}` shapes the ChatAgent
  callbacks dispatch on). `StreamHandler` keeps thin delegating defs so
  its public API is unchanged for callers.
  """

  alias Loopyard.ChatAgent.{MessageLog, SessionManager, StreamHandler}
  alias Loopyard.Events

  @ets_table :chat_agents

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

    # Count recent auto-restarts (last 60s) so a deterministically dying CLI
    # doesn't hot-loop. Must match the marker actually written below — the old
    # literal ("Agent crashed — restarting...") was never emitted, so the
    # breaker was dead (#42).
    recent_crashes =
      state.messages
      |> Enum.count(fn m ->
        m.role == :system && is_binary(m.content) &&
          String.starts_with?(m.content, "Agent session restarted automatically") &&
          DateTime.diff(now, m.timestamp, :second) < 60
      end)

    if is_binary(reason) && String.contains?(reason, "CLI session exited") && recent_crashes < 2 do
      # CLI died — restart session and resume the same conversation
      state =
        SessionManager.note_cli_death(%{state | last_activity_at: now, errors: state.errors + 1})

      restart_or_compact(state, id)
    else
      stream_error_no_restart(state, id, reason, now)
    end
  end

  # Breaker tripped → don't resume the session that keeps killing its harness;
  # funnel through :restart_session, whose gate compacts (summarize → fresh
  # session). Otherwise: spawn a new CLI resuming the same conversation.
  defp restart_or_compact(state, id) do
    if Loopyard.ChatAgent.compaction_breaker_tripped?(state) do
      GenServer.cast(self(), :restart_session)
      state = Map.put(state, :active_tool, nil)
      :ets.insert(@ets_table, {id, Loopyard.ChatAgent.summary(state)})
      {:noreply, state}
    else
      case SessionManager.start_session_safe(state) do
        {:ok, new_session, live_id} ->
          recovered_msg =
            if is_binary(live_id) do
              %{
                role: :system,
                content:
                  "Agent session restarted automatically (resumed conversation #{String.slice(live_id, 0..7)}…).",
                timestamp: DateTime.utc_now()
              }
            else
              %{
                role: :system,
                content: "Agent session restarted automatically (fresh conversation).",
                timestamp: DateTime.utc_now()
              }
            end

          {state, recovered_msg} =
            MessageLog.append(
              SessionManager.track_os_pid(%{
                state
                | session: new_session,
                  claude_session_id: live_id,
                  status: :idle,
                  active_tool: nil
              }),
              recovered_msg
            )

          Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{
            agent_id: id,
            msg: recovered_msg
          })

          :ets.insert(@ets_table, {id, Loopyard.ChatAgent.summary(state)})
          Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: id, status: :idle})

          # A fresh session (no live id) needs its prior context replayed;
          # a resumed one already has it.
          if is_nil(live_id) do
            {:build_resume, state}
          else
            StreamHandler.drain_pending_sends(state)
          end

        {:error, reason, next_hint} ->
          state = %{state | claude_session_id: next_hint}

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

          {state, fail_msg} = MessageLog.append(state, fail_msg)
          state = StreamHandler.reset_turn_state(%{state | status: :idle})

          Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{
            agent_id: id,
            msg: fail_msg
          })

          :ets.insert(@ets_table, {id, Loopyard.ChatAgent.summary(state)})
          Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: id, status: :idle})
          StreamHandler.drain_pending_sends(state)
      end
    end
  end

  # Unrecoverable stream error: drop the turn, surface the
  # WHY/CONSEQUENCE/ACTION error, settle to idle.
  defp stream_error_no_restart(state, id, reason, now) do
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

    {state, error_msg} = MessageLog.append(state, error_msg)

    state =
      StreamHandler.reset_turn_state(%{
        state
        | status: :idle,
          last_activity_at: now,
          errors: state.errors + 1
      })

    Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{
      agent_id: id,
      msg: error_msg
    })

    :ets.insert(@ets_table, {id, Loopyard.ChatAgent.summary(state)})
    Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: id, status: :idle})
    StreamHandler.drain_pending_sends(state)
  end

  @doc """
  Handle a stream timeout. Returns `{:reboot, state}`.
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

    {state, error_msg} = MessageLog.append(state, error_msg)

    # Clear stream_ref too: the wedged Task may still be alive, and dropping its
    # ref means late events are ignored, not applied to a now-"idle" agent (if
    # the reboot below fails and leaves us resting).
    state =
      StreamHandler.reset_turn_state(%{
        state
        | status: :idle,
          errors: state.errors + 1,
          stream_ref: nil
      })

    Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{
      agent_id: id,
      msg: error_msg
    })

    :ets.insert(@ets_table, {id, Loopyard.ChatAgent.summary(state)})
    Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: id, status: :idle})

    # Reboot the harness (keeps history, resumes via claude_session_id). Queued
    # messages drain onto the fresh CLI inside the restart path — NOT here, so we
    # never drain onto the wedged session we're about to replace.
    {:reboot, state}
  end

  @doc """
  Finalize any partial text accumulated from TextDelta events when a stream is
  interrupted (error, timeout, user stop). Delegates to
  `Loopyard.ChatAgent.PartialText` — kept as a thin passthrough so existing
  callers (StreamHandler + ChatAgent) don't need to change. Queued delta
  chunks are dropped first: the finalized partial Message carries the full
  accumulated text, and a flush landing after it would ghost a stale
  streaming bubble in every viewer.
  """
  def finalize_partial_on_stream_interrupt(state, id, reason) do
    state
    |> StreamHandler.drop_stream_deltas()
    |> Loopyard.ChatAgent.PartialText.finalize(id, reason)
  end
end
