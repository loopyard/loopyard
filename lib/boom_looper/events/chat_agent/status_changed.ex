defmodule BoomLooper.Events.ChatAgent.StatusChanged do
  @moduledoc "Agent status changed (:idle | :thinking | :crashed | :destroying | ...)."
  defstruct [:id, :status]
end
