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

  @type t ::
          TextDelta.t()
          | Text.t()
          | ToolCall.t()
          | ToolResult.t()
          | SessionResult.t()
end
