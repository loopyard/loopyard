defmodule Loopyard.Events.ChatAgent.Removed do
  @moduledoc "Agent removed from the workspace."
  defstruct [:id]
  @type t :: %__MODULE__{}
end
