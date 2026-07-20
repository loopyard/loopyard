defmodule Loopyard.Agent.Event.ToolCall do
  @moduledoc """
  The assistant is invoking a tool.

  `kind` is the neutral, harness-agnostic classification the UI renders by
  (`t:Loopyard.Agent.ToolKind.t/0`). A backend MAY set it to render its own
  tool vocabulary correctly; when `nil`, consumers classify from `name` via
  `Loopyard.Agent.ToolKind.classify/1`. This is the seam that keeps the door
  open for our own harnesses — the UI never matches raw tool names itself.
  """
  defstruct [:id, :name, :input, :kind]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          name: String.t(),
          input: map(),
          kind: Loopyard.Agent.ToolKind.t() | nil
        }
end
