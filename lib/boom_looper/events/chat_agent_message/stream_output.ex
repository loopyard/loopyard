defmodule BoomLooper.Events.ChatAgentMessage.StreamOutput do
  @moduledoc "Streaming command output (docker compose build, exec_stream, etc.) attached to a streaming-message id; `title` is a short label."
  defstruct [:agent_id, :data, :title, :msg_id]
end
