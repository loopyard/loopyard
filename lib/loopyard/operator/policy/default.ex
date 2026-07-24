defmodule Loopyard.Operator.Policy.Default do
  @moduledoc """
  The first, deliberately DUMB attention policy: group by state
  (blocked > finished > working > idle), most-recent first within a group. No
  weights, no dials yet — we add them only if watching the live board shows order
  earns its keep (it's a clue, not an authority). Swap this module (or add
  `config :loopyard, operator_policy: …`) to try something richer.
  """
  @behaviour Loopyard.Operator.Policy

  # Worker-queue order: needs-you (blocked) > done (unread result) > chugging.
  @state_rank %{needs_you: 0, done: 1, chugging: 2}

  @impl true
  def rank(items, _opts) do
    Enum.sort_by(items, fn i -> {Map.get(@state_rank, i.state, 9), -recency(i)} end)
  end

  defp recency(%{last_activity_at: %DateTime{} = at}), do: DateTime.to_unix(at)
  defp recency(_), do: 0
end
