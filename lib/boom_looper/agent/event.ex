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

  @type t ::
          TextDelta.t()
          | Text.t()
          | ToolCall.t()
          | ToolResult.t()
end
