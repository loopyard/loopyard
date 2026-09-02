defmodule Loopyard.Events.ChatAgentMessage.TextDelta do
  @moduledoc "Streaming text chunk from Claude; not persisted — UI uses it to render \"typing\" output between full `Message` events."
  defstruct [:agent_id, :text]
  @type t :: %__MODULE__{}
end
