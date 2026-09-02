defmodule Loopyard.ChatAgent.Thread do
  @moduledoc """
  Decision threads — a chat message that is ABOUT a pending decision card.

  A decision is a card in some agent's conversation (`role: :question` /
  `:approval` / `:secret_request`). The decision page lets a human talk to the
  operator about that one card while it stays on screen; for the reply to land
  back on the page instead of only in the operator's chat, both the human's
  message and the operator's answer must carry the card's reference.

  The reference rides IN the message text as a leading marker line
  (`[[re:<agent_id>:<msg_id>]]`), stripped when the user message is appended
  and re-stamped as `re: {agent_id, msg_id}` on it — so it survives every path
  a send can take (parked in `pending_sends`, drained as a batch, delivered as
  a late answer) without changing the shape of the queue those paths share.
  The operator's reply inherits the `re` of the human message that started
  the turn (`reply_re/1`).

  The model never sees the marker: `frame_prompt/2` replaces it with the card
  itself, so the operator knows which decision the human is looking at.
  """

  @marker ~r/\A\[\[re:([^:\]]+):([^\]]+)\]\]\n?/

  @typedoc "A decision reference: the agent that asked and the card's message id."
  @type ref :: {String.t(), String.t()}

  @doc "Prefix `text` with the marker for decision `ref`."
  @spec tag(String.t(), ref()) :: String.t()
  def tag(text, {agent_id, msg_id}), do: "[[re:#{agent_id}:#{msg_id}]]\n" <> text

  @doc """
  Split a message into `{text, ref | nil}` — the text without the marker, and
  the decision it refers to, if any.
  """
  @spec split(term()) :: {term(), ref() | nil}
  def split(text) when is_binary(text) do
    case Regex.run(@marker, text) do
      [marker, agent_id, msg_id] ->
        {binary_part(text, byte_size(marker), byte_size(text) - byte_size(marker)),
         {agent_id, msg_id}}

      _ ->
        {text, nil}
    end
  end

  def split(other), do: {other, nil}

  @doc "The text a human should see — the marker gone, nothing else changed."
  @spec display(term()) :: term()
  def display(text), do: text |> split() |> elem(0)

  @doc """
  The user message to append for `text`: content without the marker, plus
  `re:` when it carried one.
  """
  @spec user_message(String.t()) :: map()
  def user_message(text) do
    {content, ref} = split(text)
    msg = %{role: :user, content: content, timestamp: DateTime.utc_now()}
    if ref, do: Map.put(msg, :re, ref), else: msg
  end

  @doc """
  What the MODEL receives for a tagged message: the decision card rendered as
  text (`Loopyard.CardText`), then the human's words. Untagged text passes
  through unchanged; a card that has since vanished degrades to the bare text.
  """
  @spec frame_prompt(String.t()) :: String.t()
  def frame_prompt(text) do
    case split(text) do
      {plain, nil} ->
        plain

      {plain, {agent_id, msg_id}} ->
        case card_text(agent_id, msg_id) do
          nil ->
            plain

          card ->
            "The user is looking at this pending decision and is asking about it. " <>
              "Answer about THIS decision — look things up (the workspace, the agent's " <>
              "recent turns, the code) if that's what it takes. Don't answer the decision " <>
              "for them unless they tell you to.\n\n" <>
              "--- decision ---\n#{card}\n--- end decision ---\n\n" <> plain
        end
    end
  end

  @doc """
  The decision reference an assistant reply should inherit: the `re` of the
  newest user message, and only for a human-started turn — a seed / resume
  prompt must not pick up the tag of whatever the human last asked about.

  `state.messages` is newest-first (O(1) append); the first `:user` hit is
  the message that started this turn.
  """
  @spec reply_re(map()) :: ref() | nil
  def reply_re(%{current_turn_origin: :human, messages: messages}) when is_list(messages) do
    case Enum.find(messages, &(&1[:role] == :user)) do
      %{re: {_, _} = ref} -> ref
      _ -> nil
    end
  end

  def reply_re(_state), do: nil

  @doc "Every message in `messages` (any order) that belongs to decision `ref`."
  @spec messages_for([map()], ref()) :: [map()]
  def messages_for(messages, ref) when is_list(messages),
    do: Enum.filter(messages, &(&1[:re] == ref))

  defp card_text(agent_id, msg_id) do
    case Loopyard.ChatAgent.get_message(agent_id, msg_id) do
      %{} = msg -> Loopyard.CardText.render(msg)
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end
end
