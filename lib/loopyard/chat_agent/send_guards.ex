defmodule Loopyard.ChatAgent.SendGuards do
  @moduledoc """
  The inbox's protective rails, extracted from ChatAgent: the bounded pending
  queue (`park_send/2` + the loud `queue_full_note/1` — a silently dropped
  message is the one unforgivable outcome) and the auth-outage card
  (`ensure_auth_fix_card/1` — one pending card per outage, never stacked).
  State in, state out; no GenServer coupling.
  """

  alias Loopyard.ChatAgent.MessageLog
  alias Loopyard.ChatAgent.Persistence
  alias Loopyard.Events

  @doc """
  Edit a queued message IN PLACE, preserving its position. `old_text` guards
  against a queue that shifted since the edit opened: replace at `index` only
  if it still holds the original; else replace wherever the original now sits;
  else (it drained/was removed) append the edit as a fresh queued line so the
  text is never silently dropped.
  """
  def update_pending(pending, index, old_text, new_text) do
    cond do
      Enum.at(pending, index) == old_text ->
        List.replace_at(pending, index, new_text)

      old_text in pending ->
        List.replace_at(pending, Enum.find_index(pending, &(&1 == old_text)), new_text)

      true ->
        pending ++ [new_text]
    end
  end

  # See ChatAgent's @max_message_bytes note: "bounded by user behavior" is
  # unbounded in multiplayer.
  @max_pending_sends 50

  # Park a message on the pending queue, bounded. :full means the caller must
  # SAY so — a silently dropped message is the one unforgivable outcome.
  def park_send(state, text) do
    if length(state.pending_sends) >= @max_pending_sends do
      :full
    else
      {:ok, %{state | pending_sends: state.pending_sends ++ [text]}}
    end
  end

  @doc """
  Park a message for the next free turn and tell the world: queue it (loudly
  refusing when full), refresh the ETS summary so the live queue band updates,
  and re-broadcast the status. The one path every "agent is busy, hold this"
  clause in ChatAgent takes — a thinking turn, a backoff, a rate limit, or an
  agent parked inside its own ask.
  """
  def park_for_later(state, text) do
    state =
      case park_send(state, text) do
        {:ok, state} -> Map.put(state, :last_enqueue, :ok)
        :full -> state |> queue_full_note() |> Map.put(:last_enqueue, :full)
      end

    :ets.insert(:chat_agents, {state.id, Loopyard.ChatAgent.summary(state)})
    Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: state.id, status: state.status})
    state
  end

  def queue_full_note(state) do
    note = %{
      role: :error,
      content:
        "Message NOT queued — #{@max_pending_sends} are already waiting. " <>
          "Wait for the agent to catch up (or Clear all in the queue panel), then resend.",
      timestamp: DateTime.utc_now()
    }

    {state, note} = MessageLog.append(state, note)

    Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{
      agent_id: state.id,
      msg: note
    })

    state
  end

  # One PENDING auth-fix card per outage: append it if the recent tail has
  # none (messages are stored reversed — newest first).
  def ensure_auth_fix_card(state) do
    has_pending? =
      state.messages
      |> Enum.take(50)
      |> Enum.any?(&(&1[:role] == :auth_fix and &1[:status] == :pending))

    if has_pending? do
      state
    else
      card = %{
        role: :auth_fix,
        status: :pending,
        workstation_id: Loopyard.Workstation.current(),
        timestamp: DateTime.utc_now()
      }

      {state, card} = MessageLog.append(state, card)
      Persistence.persist_message(state, card)

      Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{
        agent_id: state.id,
        msg: card
      })

      state
    end
  end
end
