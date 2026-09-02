defmodule Loopyard.Events.ChatAgent.Renamed do
  @moduledoc "Agent renamed."
  defstruct [:id, :name]
  @type t :: %__MODULE__{}
end
