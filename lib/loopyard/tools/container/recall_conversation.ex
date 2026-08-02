defmodule Loopyard.Tools.Container.RecallConversation do
  @moduledoc """
  Let the agent read its OWN durable conversation history from Loopyard.

  This is the keystone of harness-portable memory: the conversation lives in
  Loopyard's durable log, NOT in the harness's session. When a session is fresh
  (crash, server restart, or a deliberate model/account/harness switch) the
  agent's in-context memory is empty even though Loopyard still holds every
  message. This tool bridges that gap — the agent pulls its full history on
  demand, under ANY harness that speaks MCP (Claude Code, Codex, …).

  Read-only. The `agent_id` is bound from the verified bearer token by
  `Loopyard.MCP.ToolRouter` (never the payload), so an agent can only ever read
  its OWN transcript. Reads the `:chat_agents` ETS summary via
  `MessageWindow.get_messages/2` — no GenServer call, works even when the agent
  is mid-turn or stopped.
  """
  use Loopyard.Tool,
    name: "recall_conversation",
    description:
      "Read your own earlier conversation history with the user from Loopyard's " <>
        "durable log — use this when you don't remember something that was discussed " <>
        "earlier (e.g. after a restart or a model/harness switch your context may be " <>
        "empty even though the full history is preserved). Returns messages oldest→" <>
        "newest, and always within a bounded size so it can't flood your context. " <>
        "Three ways in: `pattern` GREPS the transcript with a regex (when you know " <>
        "the SHAPE of what you want), `query` matches plain words (when you just know " <>
        "some words), and `before_id` pages further back. Prefer searching over " <>
        "paging — it's far cheaper than reading history back.",
    params: [
      agent_id: {:string, required: true},
      limit: {:integer, description: "How many messages to return (default 30, max 200)."},
      before_id:
        {:string,
         description:
           "Return messages BEFORE this message id (for paging further back — use the before_id printed in a previous call's footer)."},
      pattern:
        {:string,
         description:
           "GREP: a regular expression to match against message text and tool names, e.g. \"(user|pass)word\\s*[:=]\" or \"sk-[A-Za-z0-9_-]{20,}\". Case-insensitive by default. Use this when you know the SHAPE of what you're after; use `query` when you just know some words. An invalid pattern is reported, never guessed at."},
      case_sensitive: {:boolean, description: "Make `pattern` case-sensitive (default false)."},
      query:
        {:string,
         description:
           "Search terms. Case-insensitive; EVERY whitespace-separated term must appear in a message (any order), so \"nfhs creds\" finds a message containing both. Searches message text AND tool names. Excerpts are centred on the match, so a hit deep inside a long message is actually shown. Returns the most recent matches (before_id is ignored when searching). PREFER this over paging when you're looking for something specific — it's far cheaper than reading history back."}
    ]

  alias Loopyard.ChatAgent.MessageWindow

  @default_limit 30
  @max_limit 200
  @body_cap 800

  # TOTAL output budget, independent of the message count. The per-message cap
  # alone doesn't bound anything useful: 200 messages x 800 bytes is ~160KB —
  # roughly 40k tokens dumped into the context by one call, which is the exact
  # thing this tool exists to avoid. We fill up to the budget newest-first and
  # say plainly how many were left out and how to reach them.
  @total_cap 12_000

  # Search excerpts are centred ON the match. Showing the first N bytes of a
  # long message is how a search can "find" something and still not show it —
  # a credential 3KB into a message was located and then truncated away.
  @excerpt_radius 320

  def execute(%{agent_id: agent_id} = params, _assigns) do
    limit = params |> Map.get(:limit) |> clamp(@default_limit, 1, @max_limit)
    query = params[:query]
    before_id = params[:before_id]

    # One ETS read of the full chronological list (≤1000 msgs in memory) — all
    # paging/search happens locally, which keeps the cursor math obvious and the
    # "N older" footer exact.
    {all, total} = MessageWindow.get_messages(agent_id, limit: 1_000_000)

    cond do
      total == 0 ->
        {:ok, "No conversation history yet — this is the start of the conversation."}

      is_binary(params[:pattern]) and String.trim(params[:pattern]) != "" ->
        grep(all, total, String.trim(params[:pattern]), params[:case_sensitive] == true, limit)

      is_binary(query) and String.trim(query) != "" ->
        search(all, total, String.trim(query), limit)

      true ->
        page(all, total, before_id, limit)
    end
  end

  # --- paging (newest window, or before a cursor) ---
  defp page(all, total, before_id, limit) do
    # Exclusive end of the window: the cursor position, or the end of the list
    # when there's no cursor (or it wasn't found → fall back to the newest page).
    stop =
      case before_id && Enum.find_index(all, &(&1[:id] == before_id)) do
        nil -> total
        idx -> idx
      end

    start = max(0, stop - limit)
    window = Enum.slice(all, start, stop - start)

    header =
      "Conversation history — #{total} message(s) total, showing #{length(window)} " <>
        "(#{if before_id, do: "before #{before_id}", else: "most recent"}), oldest first:"

    footer =
      if start > 0 do
        earliest = List.first(window)

        "\n\n(#{start} older message(s) — call recall_conversation with " <>
          "before_id=#{earliest[:id]} to read further back.)"
      else
        "\n\n(This is the beginning of the conversation.)"
      end

    {:ok, header <> "\n\n" <> render(window) <> footer}
  end

  # --- grep (regex, most-recent matches) ---
  #
  # Agents reach for grep by reflex, and the transcript is just text — the same
  # ETS list `search` already walks. Matching on the SHAPE of a thing ("a token
  # that looks like sk-…", "a line assigning a password") is what substring
  # search can't do.
  defp grep(all, total, pattern, case_sensitive?, limit) do
    opts = if case_sensitive?, do: "", else: "i"

    case Regex.compile(pattern, opts) do
      {:error, {reason, at}} ->
        {:ok,
         "Invalid pattern #{inspect(pattern)}: #{reason} at position #{at}. " <>
           "It's a regular expression — escape regex metacharacters (. * + ? [ ] ( ) | \\) " <>
           "if you meant them literally, or use `query` for plain word search."}

      {:ok, re} ->
        matches = Enum.filter(all, &Regex.match?(re, haystack(&1)))
        shown = Enum.take(matches, -limit)

        header =
          "Grep of #{total} message(s) for /#{pattern}/#{opts}: #{length(matches)} match(es)" <>
            if(length(matches) > length(shown),
              do: " (showing the #{length(shown)} most recent)",
              else: ""
            ) <> if(matches == [], do: ".", else: ", oldest first:")

        # Centre each excerpt on what actually matched IN that message, so a hit
        # deep inside a long message is shown rather than truncated away.
        annotated =
          Enum.map(shown, fn m ->
            case Regex.run(re, to_string(m[:content])) do
              [hit | _] when is_binary(hit) and hit != "" ->
                Map.put(m, :__excerpt_terms, [String.downcase(hit)])

              _ ->
                m
            end
          end)

        body = if annotated == [], do: "", else: "\n\n" <> render(annotated)
        {:ok, header <> body}
    end
  end

  # Message text PLUS the tool name — "which tool did I run" is a question about
  # the transcript like any other.
  defp haystack(m), do: to_string(m[:content]) <> " " <> to_string(m[:tool])

  # --- search (most-recent matches) ---
  defp search(all, total, query, limit) do
    # Every whitespace-separated term must appear (order-independent), so
    # "nfhs creds" finds a message containing both rather than only the exact
    # phrase. Tool NAMES are searchable too — "which tool did I run" is a
    # question about the transcript like any other.
    terms = query |> String.downcase() |> String.split(~r/\s+/, trim: true)

    matches =
      Enum.filter(all, fn m ->
        hay = m |> haystack() |> String.downcase()
        Enum.all?(terms, &String.contains?(hay, &1))
      end)

    shown = Enum.take(matches, -limit)
    match_count = length(matches)

    header =
      "Search of #{total} message(s) for \"#{query}\": #{match_count} match(es)" <>
        if(match_count > length(shown),
          do: " (showing the #{length(shown)} most recent)",
          else: ""
        ) <>
        if(match_count == 0, do: ".", else: ", oldest first:")

    annotated = Enum.map(shown, &Map.put(&1, :__excerpt_terms, terms))
    body = if annotated == [], do: "", else: "\n\n" <> render(annotated)
    {:ok, header <> body}
  end

  # --- rendering ---
  #
  # Renders NEWEST-first into the byte budget, then flips back to chronological
  # order for the reader. Dropping from the OLD end is the right trade: the most
  # recent context is what an agent that has lost its memory needs first, and
  # the footer tells it exactly how to page further back.
  defp render(messages) do
    {kept, omitted} = fit_to_budget(messages)

    body = kept |> Enum.map_join("\n\n", &render_one/1)

    if omitted > 0 do
      "(#{omitted} older message(s) in this window omitted to stay within the " <>
        "context budget — narrow with `query`, or page with `before_id`.)\n\n" <> body
    else
      body
    end
  end

  # Fill newest-first until the budget is spent. Always keeps at least one
  # message, so a single oversized message still returns something.
  defp fit_to_budget(messages) do
    {kept_rev, _spent} =
      messages
      |> Enum.reverse()
      |> Enum.reduce_while({[], 0}, fn m, {acc, spent} ->
        cost = m |> render_one() |> byte_size()

        cond do
          acc == [] -> {:cont, {[m], cost}}
          spent + cost > @total_cap -> {:halt, {acc, spent}}
          true -> {:cont, {[m | acc], spent + cost}}
        end
      end)

    {kept_rev, length(messages) - length(kept_rev)}
  end

  defp render_one(m) do
    terms = Map.get(m, :__excerpt_terms, [])

    who =
      case m[:role] do
        :user -> "User"
        :assistant -> "You (assistant)"
        :tool -> "Tool" <> if(m[:tool], do: "(#{m[:tool]})", else: "")
        :error -> "Error"
        :build_done -> "System"
        _ -> "System"
      end

    "#{who}#{ts(m[:timestamp])} (id #{m[:id]}): #{body(m[:content], terms)}"
  end

  # No search terms: the head of the message, capped.
  defp body(content, []), do: clip_head(to_string(content))

  # Searching: centre the excerpt ON the first matching term. Showing the head
  # of a long message is how a search finds something and still doesn't show it.
  defp body(content, terms) do
    text = to_string(content)
    down = String.downcase(text)

    case terms |> Enum.map(&:binary.match(down, &1)) |> Enum.reject(&(&1 == :nomatch)) do
      [] ->
        clip_head(text)

      hits ->
        {at, _} = Enum.min_by(hits, fn {a, _} -> a end)
        excerpt(text, at)
    end
  end

  defp clip_head(text) do
    if byte_size(text) > @body_cap do
      String.slice(text, 0, @body_cap) <> "… [truncated — #{byte_size(text)} bytes]"
    else
      text
    end
  end

  defp excerpt(text, _at) when byte_size(text) <= @body_cap, do: text

  defp excerpt(text, at) do
    start = max(0, at - @excerpt_radius)
    len = @excerpt_radius * 2

    lead = if start > 0, do: "…", else: ""
    trail = if start + len < byte_size(text), do: "…", else: ""

    lead <>
      binary_part(text, start, min(len, byte_size(text) - start)) <>
      trail <> " [match shown; full message #{byte_size(text)} bytes]"
  end

  defp ts(%DateTime{} = dt),
    do:
      " [" <>
        (dt |> DateTime.to_iso8601() |> String.slice(0, 16) |> String.replace("T", " ")) <> "]"

  defp ts(_), do: ""

  defp clamp(n, _default, lo, hi) when is_integer(n), do: n |> max(lo) |> min(hi)
  defp clamp(_, default, _lo, _hi), do: default
end
