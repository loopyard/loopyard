defmodule Loopyard.Events.ChatAgent.Stopped do
  @moduledoc "Agent stopped normally OR crashed (callers differentiate via summary.status)."
  defstruct [:summary]
  @type t :: %__MODULE__{}
end
