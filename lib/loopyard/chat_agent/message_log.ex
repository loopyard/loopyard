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

  # Re-apply outstanding card patches (see MessageWindow.update_message_now):
  # a summary built from state that predates a card interaction must not undo
  # it. Fast path (no patches) is one ETS match on a tiny table.
  def reconcile_card_patches(agent_id, messages) do
    case :ets.match_object(:card_patches, {{agent_id, :_}, :_}) do
      [] ->
        messages

      patches ->
        by_msg = Map.new(patches, fn {{_aid, msg_id}, changes} -> {msg_id, changes} end)

        Enum.map(messages, fn msg ->
          case Map.get(by_msg, msg[:id]) do
            nil ->
              msg

            changes ->
              # NB: monotonic time is NEGATIVE on most systems — no numeric
              # sentinel; nil msg card_v means "never patched", always apply.
              msg_v = msg[:card_v]

              if is_nil(msg_v) or (changes[:card_v] && changes[:card_v] > msg_v),
                do: Map.merge(msg, changes),
                else: msg
          end
        end)
    end
  rescue
    _ -> messages
  end
end
