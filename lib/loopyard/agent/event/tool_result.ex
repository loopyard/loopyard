defmodule Loopyard.Agent.Event.ToolResult do
  @moduledoc "Output from a completed tool invocation."
  defstruct [:id, :content, is_error: false]
  @type t :: %__MODULE__{id: String.t() | nil, content: String.t(), is_error: boolean()}
end
