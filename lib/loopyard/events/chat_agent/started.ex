defmodule Loopyard.Events.ChatAgent.Started do
  @moduledoc "Agent started fresh; payload is the summary map that ETS stores."
  defstruct [:summary]
  @type t :: %__MODULE__{}
end
