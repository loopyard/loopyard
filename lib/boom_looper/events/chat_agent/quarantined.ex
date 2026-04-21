defmodule BoomLooper.Events.ChatAgent.Quarantined do
  @moduledoc "Agent quarantined due to crash-loop."
  defstruct [:id, :summary]
end
