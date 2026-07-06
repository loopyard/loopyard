defmodule LoopyardWeb.Live.WorkspaceLive.Messages.Transcript do
  @moduledoc """
  Pure transcript-structure helpers for the run-spine chat layout:
  grouping consecutive agent messages into runs, and sectioning the
  transcript so each human prompt owns the response beneath it.

  Split out of `LoopyardWeb.Live.WorkspaceLive.Messages` to keep that
  module under its size cap. `Messages` re-exposes `transcript_groups/1`
  and `transcript_sections/1` via `defdelegate`, so chat_panel and the
  transcript-layout tests are unchanged. This module is data-only (list
  transforms over the message list) — no templates, no sockets.
  """

  @doc """
  Group the message list into transcript segments for the run-spine layout.

  Returns an ordered list of:
    * `{:run, [{msg, idx}]}` — consecutive agent-authored messages that share
      ONE spine + ONE "Claude" header.
    * `{:break, {msg, idx}}` — a human-facing message (user bubble, or a
      question/approval card) that stands alone and breaks the run.

  Indices are the original positions in `messages` (so `chat_msg` look-back
  helpers still work).
  """
  def transcript_groups(messages) do
    messages
    |> Enum.with_index()
    |> Enum.reduce([], fn {msg, idx}, groups ->
      cond do
        break_msg?(msg) ->
          [{:break, {msg, idx}} | groups]

        match?([{:run, _} | _], groups) ->
          [{:run, items} | rest] = groups
          [{:run, [{msg, idx} | items]} | rest]

        true ->
          [{:run, [{msg, idx}]} | groups]
      end
    end)
    |> Enum.map(fn
      {:run, items} -> {:run, Enum.reverse(items)}
      other -> other
    end)
    |> Enum.reverse()
  end

  # Human-facing roles break a run: the user bubble, and the ask_user /
  # approval cards (which are answered by a human).
  defp break_msg?(%{role: role}), do: role in [:user, :question, :approval]
  defp break_msg?(_), do: false

  @doc """
  Group the transcript into SECTIONS for the sticky-prompt layout.

  Each section is `%{prompt: {msg, idx} | nil, body: [group]}` where a new
  section begins at every human **prompt** (`:user`) and `body` is the
  transcript groups (runs + question/approval cards) that answer it. The leading
  section before the first prompt has `prompt: nil`.

  The point: chat_panel wraps each section in a `<section>` and makes the prompt
  `sticky` — so the prompt that owns the response you're scrolling stays pinned
  at the top until the next prompt's section takes over.
  """
  def transcript_sections(messages) do
    messages
    |> transcript_groups()
    |> Enum.reduce([], fn group, sections ->
      case group do
        {:break, {%{role: :user}, _idx}} = prompt ->
          {:break, p} = prompt

          # A consecutive human message with NO agent response yet folds into the
          # SAME section's body — a flurry of messages becomes ONE "You" area
          # instead of a new chapter (and a new card) per line. Folds repeatedly
          # (3rd, 4th, …) until the agent actually answers (a :run appears).
          if foldable_user_section?(sections) do
            [sec | rest] = sections
            [%{sec | body: [prompt | sec.body]} | rest]
          else
            [%{prompt: p, body: []} | sections]
          end

        other ->
          case sections do
            [%{body: body} = sec | rest] -> [%{sec | body: [other | body]} | rest]
            [] -> [%{prompt: nil, body: [other]}]
          end
      end
    end)
    |> Enum.map(fn %{body: body} = sec -> %{sec | body: Enum.reverse(body)} end)
    |> Enum.reverse()
  end

  # The current (most recent) section is a human-prompt section that the agent
  # hasn't answered yet — its body has no agent run, only earlier folded prompts.
  # A new human message folds into it (same "You" area) rather than starting a new
  # chapter.
  defp foldable_user_section?([%{prompt: {%{role: :user}, _}, body: body} | _]),
    do: not Enum.any?(body, &match?({:run, _}, &1))

  defp foldable_user_section?(_), do: false
end
