defmodule BoomLooper.Events.ChatAgent.BootStatus do
  @moduledoc "Boot progress tick; `status` is a short human-readable string."
  defstruct [:id, :status]
end
