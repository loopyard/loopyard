defmodule BoomLooper.Agent.Event.ToolCall do
  @moduledoc "The assistant is invoking a tool."
  defstruct [:id, :name, :input]
  @type t :: %__MODULE__{id: String.t() | nil, name: String.t(), input: map()}
end
