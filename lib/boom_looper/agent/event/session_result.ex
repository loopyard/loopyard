defmodule BoomLooper.Agent.Event.SessionResult do
  @moduledoc "End-of-turn summary with token usage, cost, and model info."
  defstruct [
    :model,
    :input_tokens,
    :output_tokens,
    :cache_read_tokens,
    :cost_usd,
    :duration_ms,
    :num_turns
  ]

  @type t :: %__MODULE__{
          model: String.t() | nil,
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          cache_read_tokens: non_neg_integer(),
          cost_usd: float(),
          duration_ms: float(),
          num_turns: non_neg_integer()
        }
end
