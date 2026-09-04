defmodule Loopyard.Notifications.Priority do
  @moduledoc """
  The ORDER of the inbox, in one pure place (plans/notifications-and-agents.md,
  Track A step 3). The top of the inbox has to be the right thing, or the
  inbox is just a list.

  Tiers, first to last: a pin, then approvals (a turn is STOPPED on one),
  questions, secrets, finished-with-changes, finished-without, then anything
  demoted. Within a tier, OLDEST first — the inbox is a queue you work
  through, so the newest ask is the last one, not the first. Newest-first was
  tried and it inverted conversations: three questions from one turn came out
  backwards, and answering "1 of 3" meant answering the question the agent
  asked last.
  """

  alias Loopyard.Notifications.Item

  @doc "Sort key: lower sorts first."
  @spec sort_key(Item.t()) :: {integer(), integer()}
  def sort_key(%Item{} = item), do: {tier(item), unix_ms(item.raised_at)}

  @doc "Sort items into inbox order."
  @spec order([Item.t()]) :: [Item.t()]
  def order(items), do: Enum.sort_by(items, &sort_key/1)

  @doc "The tier an item sits in (0 = top)."
  @spec tier(Item.t()) :: integer()
  def tier(%Item{priority: :pinned}), do: 0
  def tier(%Item{priority: :demoted}), do: 9
  def tier(%Item{kind: :approval}), do: 1
  def tier(%Item{kind: :question}), do: 2
  def tier(%Item{kind: :secret}), do: 3

  def tier(%Item{kind: :finished, meta: %{changes: %{added: a, removed: r}}}) when a + r > 0,
    do: 4

  def tier(%Item{kind: :finished}), do: 5
  def tier(_), do: 8

  defp unix_ms(%DateTime{} = t), do: DateTime.to_unix(t, :millisecond)
  defp unix_ms(_), do: 0
end
