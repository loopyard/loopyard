defmodule Loopyard.Events.ChatAgent.Quarantined do
  @moduledoc "Agent quarantined due to crash-loop."
  defstruct [:id, :summary]
  @type t :: %__MODULE__{}
end
