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

  @doc """
  Section identity for keyed rendering: the prompt message's id (the leading
  no-prompt section keys as :head). Stable across window slides — that's what
  lets the sections `:for` skip unchanged sections instead of re-shipping
  everything when the top of the window drops.
  """
  def section_key(%{prompt: {%{id: id}, _idx}}) when not is_nil(id), do: id
  def section_key(%{prompt: {%{id: id}, _idx, _ctx}}) when not is_nil(id), do: id
  def section_key(%{prompt: {_msg, idx}}), do: {:pidx, idx}
  def section_key(%{prompt: {_msg, idx, _ctx}}), do: {:pidx, idx}
  def section_key(_), do: :head

  @doc """
  Per-item render context, precomputed in ONE pass so each transcript row's
  assigns are STABLE across appends (equal values → keyed diffing skips the
  row). Replaces the per-row look-back walks that needed the whole @messages
  list — passing that list (or any per-append-changing value) to every row
  made LiveView consider every row changed on every append (~850KB/turn
  measured). Returns idx → %{prev_role, next_role, call, streamed_exec,
  preceded_by_edit, expanded?}.
  """
  @doc """
  Sections with per-item context baked into the items: every `{msg, idx}`
  becomes `{msg, idx, ctx}`, and rows the live activity feed already shows
  (tool/tool_result past `live_from`) are FILTERED OUT here instead of a
  per-row `:if` in the template. Both matter for the wire: keyed
  comprehension tracking compares the loop variables, so context must live
  IN the item (equal tuple → row skipped), and a per-row `:if` reading a
  per-append-changing assign (`@live_tool_from`) re-dirtied every row on
  every append (~75KB/append measured).
  """
  def visible_sections(messages, expanded_results, live_from) do
    ctx = item_contexts(messages, expanded_results)

    enrich = fn {msg, idx} -> {msg, idx, Map.get(ctx, idx)} end

    visible? = fn {msg, idx} ->
      not (is_integer(live_from) and idx > live_from and msg.role in [:tool, :tool_result])
    end

    messages
    |> transcript_sections()
    |> Enum.map(fn sec ->
      %{
        prompt: sec.prompt && enrich.(sec.prompt),
        body:
          sec.body
          |> Enum.map(fn
            {:break, item} ->
              if visible?.(item), do: {:break, enrich.(item)}

            {:run, items} ->
              case items |> Enum.filter(visible?) |> Enum.map(enrich) do
                [] -> nil
                kept -> {:run, kept}
              end
          end)
          |> Enum.reject(&is_nil/1)
      }
    end)
  end

  def item_contexts(messages, expanded_results) do
    tail_from = expand_tail_from(messages)
    roles = messages |> Enum.map(& &1.role) |> List.to_tuple()
    n = tuple_size(roles)

    # Pairing tracker, kept in lockstep with ToolResults.matching_tool_call/1:
    # by_id pairs results to calls via the harness toolCallId; legacy messages
    # (no tool_id) fall back to order-of-arrival within the turn (Nth result →
    # Nth call). Positional "nearest tool above me" is WRONG for parallel
    # calls — every call is emitted first, then every result.
    {ctx, _tracker} =
      messages
      |> Enum.with_index()
      |> Enum.reduce({%{}, {%{}, [], 0}}, fn {msg, idx}, {acc, {by_id, turn_calls, turn_results}} ->
        call =
          if msg.role == :tool_result do
            case msg[:tool_id] do
              tid when is_binary(tid) -> Map.get(by_id, tid)
              _ -> turn_calls |> Enum.reverse() |> Enum.at(turn_results)
            end
          end

        entry = %{
          prev_role: if(idx > 0, do: elem(roles, idx - 1)),
          next_role: if(idx < n - 1, do: elem(roles, idx + 1)),
          call: call,
          streamed_exec:
            match?(%{role: :tool, tool: t} when is_binary(t), call) &&
              String.ends_with?(call.tool, "__exec"),
          preceded_by_edit:
            match?(%{role: :tool}, call) && call_kind(call) == :edit,
          expanded?:
            cond do
              Map.get(msg, :is_error, false) == true -> :full
              MapSet.member?(expanded_results, msg[:id]) -> :full
              # Live tail: PREVIEW, not full — a fully-highlighted 300-line
              # card ships ~150KB of span soup per tool result (measured);
              # the first lines keep the "watch it work" signal and a click
              # gets the rest.
              idx >= tail_from -> :preview
              true -> false
            end
        }

        tracker =
          case msg.role do
            :user ->
              {by_id, [], 0}

            :tool ->
              by_id =
                case msg[:tool_id] do
                  tid when is_binary(tid) -> Map.put(by_id, tid, msg)
                  _ -> by_id
                end

              {by_id, [msg | turn_calls], turn_results}

            :tool_result ->
              {by_id, turn_calls, turn_results + 1}

            _ ->
              {by_id, turn_calls, turn_results}
          end

        {Map.put(acc, idx, entry), tracker}
      end)

    ctx
  end

  @doc """
  Index the auto-expanded live tail starts at: the last user prompt (their
  results are the current turn's work). Transcripts with no user prompt in
  the window fall back to the final 20 rows.
  """
  def expand_tail_from(messages) when is_list(messages) do
    case Enum.find_index(Enum.reverse(messages), &(&1.role == :user)) do
      nil -> max(length(messages) - 20, 0)
      rev_idx -> length(messages) - 1 - rev_idx
    end
  end

  defp call_kind(%{tool_kind: kind}) when not is_nil(kind), do: kind
  defp call_kind(%{tool: tool}) when is_binary(tool), do: Loopyard.Agent.ToolKind.classify(tool)
  defp call_kind(_), do: :generic

  # The current (most recent) section is a human-prompt section that the agent
  # hasn't answered yet — its body has no agent run, only earlier folded prompts.
  # A new human message folds into it (same "You" area) rather than starting a new
  # chapter.
  defp foldable_user_section?([%{prompt: {%{role: :user}, _}, body: body} | _]),
    do: not Enum.any?(body, &match?({:run, _}, &1))

  defp foldable_user_section?(_), do: false
end
