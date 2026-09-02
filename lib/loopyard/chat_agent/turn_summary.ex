defmodule Loopyard.ChatAgent.TurnSummary do
  @moduledoc """
  The one-line OUTCOME of a turn — what the agent said last, as a sentence.

  "Finished a turn" is true of every turn and carries no information; the
  reader wants what got done. The rule: the last paragraph of the last
  assistant message, markup stripped, first sentence, clipped on a word
  boundary. Pure — computed ONCE at turn end where the messages are in hand
  and published on the activity stream, never reconstructed later with a
  GenServer call (that was `Operator.Digest.last_said/1`).
  """

  @max 120

  @doc """
  The closing sentence from a message list, newest FIRST (ChatAgent keeps
  its messages reversed for O(1) append), or nil when there's no assistant
  prose to summarise.
  """
  @spec of_messages([map()]) :: String.t() | nil
  def of_messages(messages) when is_list(messages),
    do: Enum.find_value(messages, &closing_sentence/1)

  def of_messages(_), do: nil

  @doc "Same, for a chronological (oldest-first) list — the summary shape."
  @spec of_transcript([map()]) :: String.t() | nil
  def of_transcript(messages) when is_list(messages),
    do: messages |> Enum.reverse() |> of_messages()

  def of_transcript(_), do: nil

  @doc "Max length of a summary, in bytes, before the ellipsis."
  def max, do: @max

  defp closing_sentence(%{role: :assistant, content: text}) when is_binary(text) do
    text
    |> String.split(~r/\n{2,}/, trim: true)
    |> List.last()
    |> case do
      nil -> nil
      para -> para |> strip_markup() |> first_sentence() |> presence()
    end
  end

  defp closing_sentence(_), do: nil

  # One plain line — headings, bullets, emphasis and code fences are noise once
  # the text is stripped to a sentence.
  defp strip_markup(text) do
    text
    |> String.replace(~r/```.*?```/s, "")
    |> String.replace(~r/^[\s>#*\-]+/m, "")
    |> String.replace(~r/[*`]/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp first_sentence(text) do
    text
    |> String.split(~r/(?<=[.!?])\s+/, parts: 2)
    |> hd()
    |> clip()
  end

  # Cut on a word boundary — a summary sheared mid-word reads as corruption.
  defp clip(text) when byte_size(text) <= @max, do: text

  defp clip(text) do
    text
    |> String.slice(0, @max)
    |> String.replace(~r/\s+\S*$/, "")
    |> Kernel.<>("…")
  end

  defp presence(""), do: nil
  defp presence(s), do: s
end
