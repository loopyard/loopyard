defmodule Loopyard.ChatAgent.MessageLog do
  @moduledoc """
  The ONE place message-append mechanics live: id assignment + the
  in-memory message cap.

  `state.messages` is stored REVERSED (newest first) for O(1) append;
  `ChatAgent.summary/1` reverses before exposing to readers. Both
  ChatAgent and StreamHandler append through here — the cap and the
  id-generation logic must not be duplicated anywhere else. Capped at
  `@max_messages` in memory; the ETF log retains the full history.
  """

  # Max in-memory messages.
  @max_messages 1000

  @doc """
  Append `msg` to `state.messages` (reversed list for O(1) prepend),
  assigning an id if missing and trimming to the cap.
  Returns `{state, msg}` — the msg has its ID assigned.
  """
  def append(state, msg) do
    msg = Map.put_new_lazy(msg, :id, fn -> generate_msg_id() end)
    reversed = [msg | state.messages]

    reversed =
      if length(reversed) > @max_messages, do: Enum.take(reversed, @max_messages), else: reversed

    {%{state | messages: reversed}, msg}
  end

  defp generate_msg_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end
end
