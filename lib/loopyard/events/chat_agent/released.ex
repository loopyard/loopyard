defmodule Loopyard.Events.ChatAgent.Released do
  @moduledoc "Agent released from quarantine."
  defstruct [:id]
  @type t :: %__MODULE__{}
end
