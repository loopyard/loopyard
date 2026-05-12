defmodule BoomLooper.Agent.Event.ThinkingDelta do
  @moduledoc "Streaming thinking content delta."
  defstruct [:thinking]
  @type t :: %__MODULE__{thinking: String.t()}
end
