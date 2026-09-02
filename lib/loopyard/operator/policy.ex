defmodule Loopyard.Operator.Policy do
  @moduledoc """
  The swappable attention/routing policy — ALL the fiddle-able heuristics in ONE
  spot behind a behaviour, so tuning is a config number or a one-module swap (same
  pattern as the `Harness` seam). Phase 1 needs only `rank/2` (the queue order);
  `resolve_referent` (disambiguation) lands with that feature.

  Ordering is a CLUE, not an authority — the human judges. So the default impl is
  deliberately dumb; we tune it by WATCHING the real thing, not by assuming order
  matters. See plans/archive/operator-attention-queue.md.
  """
  @type item :: map()

  @callback rank([item], keyword()) :: [item]

  @doc "The configured policy module (defaults to `Operator.Policy.Default`)."
  def impl, do: Application.get_env(:loopyard, :operator_policy, Loopyard.Operator.Policy.Default)

  @doc "Rank attention-queue items via the configured policy."
  def rank(items, opts \\ []), do: impl().rank(items, opts)
end
