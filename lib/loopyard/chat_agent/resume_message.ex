defmodule Loopyard.ChatAgent.ResumeMessage do
  @moduledoc """
  Builds the "here's the conversation you're continuing" context handed to a
  freshly started harness session — after a crash, a server restart, OR a
  deliberate model/account/harness switch — so the new session continues instead
  of booting amnesic.

  The conversation lives in Loopyard's durable log, not in the harness session.
  This seed replays the RECENT turns **verbatim** (not a lossy summary — a
  summary made the agent distrust its own context: "I have no way to verify
  these claims") and tells the agent the FULL history is one `recall_conversation`
  tool call away. Plain prompt text, so it works for ANY harness (Claude Code,
  Codex, …). Fed as a silent continuation via `{:resume_prompt, text}` — it is
  NOT recorded as a user message, so the human doesn't see a wall of replayed
  text.

  Pure — extracted from `Loopyard.ChatAgent` to keep that module under its size
  cap.
  """

  # How many recent non-tool messages to replay verbatim. Enough to answer
  # "where were we?" without re-feeding the whole (possibly huge) transcript —
  # the rest is a recall_conversation call away.
  @seed_turns 12
  # Below this there's too little history to bother seeding (a brand-new agent).
  @min_to_seed 2
  # Per-message cap so one giant message can't blow up the seed. The full message
  # is always retrievable via recall_conversation.
  @body_cap 1500

  @doc """
  A verbatim seed of the recent conversation for a fresh session, or `nil` when
  there's too little history (< #{@min_to_seed} messages) to bother.

  `messages` is newest-first (live GenServer order), each
  `%{role:, content:, timestamp:, tool:}`.
  """
  @spec build([map()]) :: String.t() | nil
  def build(messages) when is_list(messages) do
    total = length(messages)

    recent =
      messages
      # Tool-output messages are bulky and low-signal for orientation; the agent
      # can pull them with recall_conversation if it needs them.
      |> Enum.reject(&(&1[:role] == :tool))
      |> Enum.take(@seed_turns)
      |> Enum.reverse()

    if length(recent) < @min_to_seed do
      nil
    else
      preamble =
        "You are continuing an existing conversation with the user. There are " <>
          "#{total} earlier message(s) that are NOT in your current context (your " <>
          "session was restarted or switched — the conversation itself is fully " <>
          "preserved). Here are the most recent messages, verbatim:"

      footer =
        "---\n" <>
          "The FULL history is preserved. Call the `recall_conversation` tool " <>
          "(limit / before_id / query) to read anything earlier you need. Continue " <>
          "from here — do not restart the task or re-introduce yourself."

      preamble <> "\n\n" <> Enum.map_join(recent, "\n\n", &render_one/1) <> "\n\n" <> footer
    end
  end

  def build(_), do: nil

  defp render_one(m) do
    who =
      case m[:role] do
        :user -> "User"
        :assistant -> "You (assistant)"
        :error -> "Error"
        _ -> "System"
      end

    "#{who}: #{body(m[:content])}"
  end

  defp body(content) do
    text = to_string(content)

    if byte_size(text) > @body_cap do
      String.slice(text, 0, @body_cap) <>
        "… [truncated — call recall_conversation for the full message]"
    else
      text
    end
  end
end
