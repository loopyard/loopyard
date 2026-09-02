defmodule Loopyard.Notifications.Reconcile do
  @moduledoc """
  Belt and braces for the store: the CARD is the truth for a decision, and
  this sweep re-derives open decisions from the cards so nothing waiting can
  be missing and nothing settled can linger — whatever path raised or settled
  it (a broker, a late answer, an orphan rebuilt from a card, a restart that
  replayed the agent log).

  This is the scan `Loopyard.Attention.line/0` used to run on EVERY render of
  every surface (every agent's whole message list copied out of ETS). It now
  runs once per sweep in one process, and only diffs.
  """

  alias Loopyard.Notifications.Item

  @tail 200

  @doc """
  Diff the pending cards against the open decision items. Returns
  `{to_raise, to_settle}`: cards with no open item, and open items whose card
  is no longer pending (`{item, outcome}`). An agent with no ETS row at all is
  reported under `:gone` so the caller can decide (right after boot the rows
  may simply not be restored yet).
  """
  @spec diff([Item.t()]) :: %{raise: [Item.t()], settle: [{Item.t(), term()}], gone: [Item.t()]}
  def diff(open_items) do
    summaries = agent_summaries()
    by_agent = Map.new(summaries, &{&1.id, &1})

    pending =
      for %{id: aid} = st <- summaries,
          msg <- st |> Map.get(:messages, []) |> Enum.take(-@tail),
          msg[:status] == :pending,
          Item.kind_for_role(msg[:role]) != nil,
          into: %{} do
        {Item.card_id(msg), {aid, msg}}
      end

    open_ids = MapSet.new(open_items, & &1.id)

    to_raise =
      for {id, {aid, msg}} <- pending,
          not MapSet.member?(open_ids, id),
          item = Item.from_card(aid, msg),
          item != nil,
          do: item

    {to_settle, gone} =
      Enum.reduce(open_items, {[], []}, fn item, {settle, gone} ->
        cond do
          Map.has_key?(pending, item.id) ->
            {settle, gone}

          not Map.has_key?(by_agent, item.agent_id) ->
            {settle, [item | gone]}

          true ->
            {[{item, card_outcome(by_agent[item.agent_id], item.msg_id)} | settle], gone}
        end
      end)

    %{raise: to_raise, settle: to_settle, gone: gone}
  end

  # The card's final status, if the card can still be found; :gone otherwise.
  defp card_outcome(summary, msg_id) do
    case Enum.find(Map.get(summary, :messages, []), &(&1[:id] == msg_id)) do
      %{status: status} -> status
      _ -> :gone
    end
  end

  @doc "Withdraw a decision's card (see `Loopyard.Notifications.Retract`)."
  def retract_card(%Item{} = item, reason),
    do: Loopyard.Notifications.Retract.card(item, to_string(reason || "no longer needed"))

  defp agent_summaries do
    Loopyard.ChatAgent.list_agent_summaries()
  rescue
    _ -> []
  catch
    _, _ -> []
  end
end
