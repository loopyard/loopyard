defmodule BoomLooper.Events.ChatAgentMessage.Message do
  @moduledoc "One completed chat message appended to the agent's log; `msg` is the message map with at least `:role`, `:content`, `:timestamp`, `:id`."
  defstruct [:agent_id, :msg]
end
