defmodule Loopyard.Agent.Event.Thinking do
  @moduledoc "Extended thinking content from Claude's reasoning."
  defstruct [:thinking]
  @type t :: %__MODULE__{thinking: String.t()}
end
