defmodule Loopyard.Harness.ACP.Connection.Usage do
  @moduledoc """
  Token + cost accounting for `Loopyard.Harness.ACP.Connection`.

  Two frames carry the numbers, and they mean different things:

    * `usage_update` (notification) — the session's context fullness (`used` /
      `size`) and its CUMULATIVE cost so far.
    * the `session/prompt` result — that turn's real
      `inputTokens` / `outputTokens` / `cachedReadTokens`.

  Cost is the one with a trap in it. The adapter passes through the Claude Agent
  SDK's `total_cost_usd`, documented as "cumulative across turns in
  streaming-input sessions — read the latest result rather than summing", and it
  restarts from zero on a resumed session or a mid-session `/clear`. Loopyard's
  `SessionResult.cost_usd` is a PER-TURN figure that `StreamHandler` adds to the
  agent's lifetime total, so handing it the cumulative number would multiply
  spend by the turn count.

  Hence the split: the cumulative value is banked on the Connection (it is
  session-scoped state, and the Translator is rebuilt per turn), and converted
  to a delta at settle time.
  """

  @doc """
  Bank the cumulative cost carried by a `usage_update`. Any other update, or one
  without a usable amount, passes the state through untouched.
  """
  def capture(state, %{"sessionUpdate" => "usage_update"} = update) do
    case get_in(update, ["cost", "amount"]) do
      amount when is_number(amount) and amount >= 0 -> %{state | session_cost_usd: amount * 1.0}
      _ -> state
    end
  end

  def capture(state, _update), do: state

  @doc """
  This turn's accounting, from the `session/prompt` result plus the banked cost.

  Absent counts are simply omitted, so the Translator falls back to its own
  estimate rather than reporting a confident zero.
  """
  def for_turn(msg, state) do
    usage = get_in(msg, ["result", "usage"]) || %{}

    %{cost_usd: cost_delta(state)}
    |> put_count(:input_tokens, usage["inputTokens"])
    |> put_count(:output_tokens, usage["outputTokens"])
    |> put_count(:cache_read_tokens, usage["cachedReadTokens"])
  end

  @doc "Mark the banked cumulative cost as reported — call once a turn settles."
  def mark_reported(state), do: %{state | reported_cost_usd: state.session_cost_usd}

  # Per-turn cost = spent so far minus what we've already reported. A cumulative
  # figure that went DOWN means the counter reset (resume, /clear): treat the new
  # value as the whole delta. Clamping to zero instead would swallow every turn
  # until spend climbed back past the old high-water mark.
  defp cost_delta(%{session_cost_usd: current, reported_cost_usd: reported}) do
    if current < reported, do: current, else: current - reported
  end

  defp put_count(acc, key, value) when is_integer(value) and value >= 0,
    do: Map.put(acc, key, value)

  defp put_count(acc, _key, _value), do: acc
end
