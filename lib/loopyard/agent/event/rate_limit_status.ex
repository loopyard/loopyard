defmodule Loopyard.Agent.Event.RateLimitStatus do
  @moduledoc """
  Claude API rate-limit snapshot emitted by the CLI. `:allowed` is the
  normal path, `:allowed_warning` means we're approaching the cap,
  `:rejected` means the next request WILL fail until `resets_at_ms`.
  ChatAgent uses `:rejected` to transition to `:rate_limited` and
  schedule a timed retry, not a blind exponential backoff against a
  known-hard limit.
  """
  defstruct [:status, :resets_at_ms, :utilization, :rate_limit_type, :is_using_overage]
  @type status :: :allowed | :allowed_warning | :rejected
  @type t :: %__MODULE__{
          status: status(),
          resets_at_ms: integer() | nil,
          utilization: float() | nil,
          rate_limit_type: String.t() | nil,
          is_using_overage: boolean() | nil
        }
end
