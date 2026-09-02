defmodule Loopyard.Events.ChatAgentMessage.MessageUpdated do
  @moduledoc """
  An EXISTING message changed in place — e.g. a question card flipping
  `:pending → :answered`, an approval card resolving, a partial message being
  finalized. `msg` is the FULL updated message map (same shape as `Message`),
  so subscribers replace by `msg.id` rather than patching fields. Without this
  event, in-place updates reached ETS + the ETF log but never a connected
  viewer — an answered question card stayed visually pending until a reload.
  """
  defstruct [:agent_id, :msg]
  @type t :: %__MODULE__{}
end
