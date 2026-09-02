defmodule Loopyard.Events.ChatAgent.StatusChanged do
  @moduledoc "Agent status changed (:idle | :thinking | :crashed | :destroying | ...)."
  defstruct [:id, :status]
  @type t :: %__MODULE__{}
end
