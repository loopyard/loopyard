defmodule Loopyard.Agent.Event.SessionResult do
  @moduledoc """
  End-of-turn summary with token usage, cost, and model info.

  `is_error` + `error_subtype` mirror the SDK's `ResultMessage` failure
  signal (e.g. `"error_during_execution"` for an upstream 529/overload).
  A failed turn is otherwise shaped exactly like a successful one, so this
  flag is the only honest way to know the turn didn't really complete —
  it's what drives the bounded auto-retry.
  """
  defstruct [
    :model,
    is_error: false,
    error_subtype: nil,
    # Numeric fields default to 0 so a result is always safe to fold into the
    # running totals (`total + result.x`) even if a field is absent.
    input_tokens: 0,
    output_tokens: 0,
    cache_read_tokens: 0,
    cost_usd: 0.0,
    duration_ms: 0.0,
    num_turns: 0,
    # How full the CONTEXT WINDOW is right now — a session-scoped level, not a
    # per-turn amount, and therefore not summable. Kept separate from
    # `input_tokens` because the two answer different questions: input/output/
    # cache_read accumulate into the agent's lifetime totals, while this drives
    # context utilization and the proactive-compaction threshold. `nil` means
    # the harness didn't report it, and utilization falls back to the per-turn
    # input+cache figure (what backends without a context signal have always
    # done).
    context_used_tokens: nil
  ]

  @type t :: %__MODULE__{
          model: String.t() | nil,
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          cache_read_tokens: non_neg_integer(),
          context_used_tokens: non_neg_integer() | nil,
          cost_usd: float(),
          duration_ms: float(),
          num_turns: non_neg_integer(),
          is_error: boolean(),
          error_subtype: String.t() | nil
        }
end
