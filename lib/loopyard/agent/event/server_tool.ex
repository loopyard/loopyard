defmodule Loopyard.Agent.Event.ServerTool do
  @moduledoc "Claude's built-in server-side tool call (web search, code exec, etc.)."
  defstruct [:name, :input]
  @type t :: %__MODULE__{name: String.t(), input: map()}
end
