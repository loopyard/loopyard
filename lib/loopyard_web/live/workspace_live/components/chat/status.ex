defmodule LoopyardWeb.Live.WorkspaceLive.Components.Chat.Status do
  @moduledoc """
  Pure status predicates for the chat panel — what the agent/turn is doing
  right now, derived from the agent map + message list. Split out of
  `LoopyardWeb.Live.WorkspaceLive.Components.Chat` to keep that file under
  its size cap; Chat imports these back.
  """

  @doc """
  The human's display label: the workstation identity ("brad" → "Brad") the
  agent operates as, falling back to "You" when unknown. Sender identity, not
  a generic pronoun — the same name shows on committed prompts and queued ones.
  """
  def workstation_label(agent) do
    case agent && agent[:workstation_identity] do
      id when is_binary(id) and id != "" -> String.capitalize(id)
      _ -> "You"
    end
  end

  @doc """
  The ids of the prompts the agent is CURRENTLY answering — the WHOLE trailing
  batch of user messages since the last assistant reply (a rapid-fire b/c/d…
  groups into one visual block, so we highlight all of them as one, not just
  the last — a lone highlighted sub-row reads as a rendering glitch). Empty
  unless the agent is actively working, so an idle agent has no active block.
  """
  def active_prompt_ids(%{agent: agent, messages: messages}) do
    if agent[:status] in [:thinking, :backoff, :compacting] do
      messages
      |> Enum.reverse()
      |> Enum.take_while(fn m -> m[:role] != :assistant end)
      |> Enum.filter(fn m -> m[:role] == :user end)
      |> Enum.map(& &1[:id])
      |> MapSet.new()
    else
      MapSet.new()
    end
  end

  def active_prompt_ids(_), do: MapSet.new()

  @doc """
  True when the most recent question card is still unanswered. While it
  is, the agent's turn is parked inside ask_user waiting on the human —
  so the "Asking…" bouncing-dots indicator is redundant with the card
  (which already says "The agent needs your input"). Suppress the dots.
  """
  def awaiting_answer?(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find(&(&1.role == :question))
    |> case do
      %{status: :pending} -> true
      _ -> false
    end
  end

  @doc """
  True when the most recent approval card is still pending. Like the question
  case, the agent's turn is parked inside propose_* waiting on the human, so the
  "Awaiting approval…" dots are redundant with the Approve/Deny card itself.
  """
  def awaiting_approval?(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find(&(&1.role == :approval))
    |> case do
      %{status: :pending} -> true
      _ -> false
    end
  end

  @doc """
  True when a command is actively streaming into its own build bubble (the
  latest message is an in-flight role: :build, not yet :build_done/:build_failed).
  While it is, that bubble — with its live output + elapsed timer — IS the
  "watch it work" surface, so the generic "Twirling…" indicator echoing the
  same command is redundant. Suppress it.
  """
  def building?(messages) do
    match?(%{role: :build}, List.last(messages))
  end

  @doc """
  What the harness is doing right now, for the live bar's word + colour. The
  agent sets :backoff while restarting a crashed CLI and :compacting while it
  summarizes a full context; everything else reads as the model thinking.
  """
  def live_status_mode(agent, messages \\ [], streaming_text \\ "") do
    cond do
      agent.status == :backoff ->
        :restarting

      agent.status == :compacting ->
        :compacting

      # The turn is BLOCKED inside ask_user / an approval: the harness isn't
      # thinking, it's parked on a human. A violet spinner with a running
      # timer read as busywork ("Drafting a question… 2h 10m") when nothing
      # was happening but waiting. Live output wins — text still streaming
      # means it IS working, whatever else is pending.
      (streaming_text || "") == "" and
          (awaiting_answer?(messages) or awaiting_approval?(messages)) ->
        :blocked

      true ->
        :thinking
    end
  end

  @doc """
  Index of the last human message — tools after it belong to the active
  turn and live in the feed. Returns nil (suppress nothing) unless the
  feed is actually on screen, so a tool row is never hidden with no home.
  """
  def active_turn_cutoff(assigns) do
    if thinking_feed_visible?(assigns) do
      assigns.messages
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find_value(-1, fn {m, i} -> if m.role == :user, do: i end)
    end
  end

  @doc false
  def thinking_feed_visible?(assigns) do
    assigns.agent.status == :thinking and
      (assigns[:streaming_text] || "") == "" and
      (assigns[:streaming_thinking] || "") == "" and
      not awaiting_answer?(assigns.messages) and
      not awaiting_approval?(assigns.messages) and
      not building?(assigns.messages)
  end
end
