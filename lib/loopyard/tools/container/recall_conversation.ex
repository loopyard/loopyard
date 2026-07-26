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
        "newest. Page further back with before_id, or search with query.",
    params: [
      agent_id: {:string, required: true},
      limit: {:integer, description: "How many messages to return (default 30, max 200)."},
      before_id:
        {:string,
         description:
           "Return messages BEFORE this message id (for paging further back — use the before_id printed in a previous call's footer)."},
      query:
        {:string,
         description:
           "Case-insensitive substring to search message text for. Returns the most recent matches (before_id is ignored when searching)."}
    ]

  alias Loopyard.ChatAgent.MessageWindow

  @default_limit 30
  @max_limit 200
  @body_cap 800

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

  # --- search (most-recent matches) ---
  defp search(all, total, query, limit) do
    q = String.downcase(query)

    matches =
      Enum.filter(all, fn m ->
        m[:content] |> to_string() |> String.downcase() |> String.contains?(q)
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

    body = if shown == [], do: "", else: "\n\n" <> render(shown)
    {:ok, header <> body}
  end

  # --- rendering ---
  defp render(messages), do: Enum.map_join(messages, "\n\n", &render_one/1)

  defp render_one(m) do
    who =
      case m[:role] do
        :user -> "User"
        :assistant -> "You (assistant)"
        :tool -> "Tool" <> if(m[:tool], do: "(#{m[:tool]})", else: "")
        :error -> "Error"
        :build_done -> "System"
        _ -> "System"
      end

    "#{who}#{ts(m[:timestamp])}: #{body(m[:content])}"
  end

  defp body(content) do
    text = to_string(content)

    if byte_size(text) > @body_cap do
      String.slice(text, 0, @body_cap) <> "… [truncated — #{byte_size(text)} bytes]"
    else
      text
    end
  end

  defp ts(%DateTime{} = dt),
    do:
      " [" <>
        (dt |> DateTime.to_iso8601() |> String.slice(0, 16) |> String.replace("T", " ")) <> "]"

  defp ts(_), do: ""

  defp clamp(n, _default, lo, hi) when is_integer(n), do: n |> max(lo) |> min(hi)
  defp clamp(_, default, _lo, _hi), do: default
end
