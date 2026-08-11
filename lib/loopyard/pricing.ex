defmodule Loopyard.Pricing do
  @moduledoc """
  Model token pricing → dollar cost.

  The in-container ACP harness reports token usage but NOT a dollar figure
  (`cost_usd: 0.0` on every `SessionResult`), so a cost display fed straight
  from the harness is stuck at $0. But Loopyard already knows the model and the
  token counts — so it can derive the cost itself. `cost/4` turns accumulated
  tokens into USD; `StreamHandler` prefers a harness-reported cost when one is
  non-zero (a future backend that DOES report dollars) and falls back to this.

  Rates are Anthropic first-party list prices ($ per 1M tokens), matched by
  model FAMILY so both a raw id ("claude-fable-5") and a human label ("Fable 5")
  resolve. Cache reads bill at ~0.1x the input rate. Keep in sync with the
  claude-api model/pricing table when new models ship; an unknown model prices
  at the Opus tier (the workspace/operator default) rather than $0, so a missing
  entry under-reports rather than showing a misleading zero.
  """

  # {input_per_mtok, output_per_mtok} in dollars.
  @rates %{
    fable: {10.0, 50.0},
    opus: {5.0, 25.0},
    sonnet: {3.0, 15.0},
    haiku: {1.0, 5.0}
  }

  @default :opus

  @doc """
  Dollar cost for a bundle of tokens on `model`. Cache-read tokens bill at 10%
  of the input rate. Returns a float; unknown models price at the Opus tier.
  """
  @spec cost(String.t() | nil, non_neg_integer, non_neg_integer, non_neg_integer) :: float
  def cost(model, input_tokens, output_tokens, cache_read_tokens \\ 0) do
    {in_rate, out_rate} = Map.fetch!(@rates, family(model))

    per = fn tokens, rate_per_mtok -> tokens * rate_per_mtok / 1_000_000 end

    per.(input_tokens, in_rate) +
      per.(output_tokens, out_rate) +
      per.(cache_read_tokens, in_rate * 0.1)
  end

  @doc "The pricing family for a model id/label (`:fable | :opus | :sonnet | :haiku`)."
  @spec family(String.t() | nil) :: :fable | :opus | :sonnet | :haiku
  def family(model) when is_binary(model) do
    m = String.downcase(model)

    cond do
      String.contains?(m, "fable") or String.contains?(m, "mythos") -> :fable
      String.contains?(m, "opus") -> :opus
      String.contains?(m, "sonnet") -> :sonnet
      String.contains?(m, "haiku") -> :haiku
      true -> @default
    end
  end

  def family(_), do: @default
end
