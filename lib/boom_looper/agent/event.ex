defmodule BoomLooper.Agent.Event do
  @moduledoc """
  BoomLooper-native event types that decouple agent logic from any specific backend's
  message format. The UI and ChatAgent pattern-match on these structs.
  """

  defmodule TextDelta do
    @moduledoc "Streaming text fragment (partial response)."
    defstruct [:text]
    @type t :: %__MODULE__{text: String.t()}
  end

  defmodule Text do
    @moduledoc "Complete assistant text block."
    defstruct [:text]
    @type t :: %__MODULE__{text: String.t()}
  end

  defmodule ToolCall do
    @moduledoc "The assistant is invoking a tool."
    defstruct [:id, :name, :input]
    @type t :: %__MODULE__{id: String.t() | nil, name: String.t(), input: map()}
  end

  defmodule ToolResult do
    @moduledoc "Output from a completed tool invocation."
    defstruct [:id, :content, is_error: false]
    @type t :: %__MODULE__{id: String.t() | nil, content: String.t(), is_error: boolean()}
  end

  defmodule SessionResult do
    @moduledoc "End-of-turn summary with token usage, cost, and model info."
    defstruct [:model, :input_tokens, :output_tokens, :cache_read_tokens, :cost_usd, :duration_ms, :num_turns]
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

  defmodule RateLimitStatus do
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

  defmodule AuthStatus do
    @moduledoc """
    Authentication status from the Claude CLI. `error` being non-nil
    signals that the CLI can't authenticate — ChatAgent transitions to
    `:auth_expired` and stops retrying until a human intervenes (there
    is no automated recovery from bad creds).
    """
    defstruct [:is_authenticating, :error, output: []]
    @type t :: %__MODULE__{
      is_authenticating: boolean(),
      error: String.t() | nil,
      output: [String.t()]
    }
  end

  @type t ::
          TextDelta.t()
          | Text.t()
          | ToolCall.t()
          | ToolResult.t()
          | SessionResult.t()
          | RateLimitStatus.t()
          | AuthStatus.t()
end
