defmodule Loopyard.ChatAgent.MessageWindow do
  @moduledoc """
  Read-only, ETS-backed message pagination for an agent's transcript:
  the `get_messages/2` window loader and the scroll-up "snap to the
  nearest human prompt" logic.

  Split out of `Loopyard.ChatAgent` to keep that module under its size
  cap. `ChatAgent` re-exposes `get_messages/2` via `defdelegate`, so
  every call site (LiveView, HarnessCheck, tests) is unchanged.
  """

  @ets_table :chat_agents

  # Hard ceiling on a single snap-to-prompt scroll-up load. The base page is 50;
  # snapping extends up to the nearest "You" prompt, but never past this many
  # messages total — so one absurdly long agent run (100s of tool messages in a
  # single group) can't turn one scroll-up into a giant, slow render.
  @snap_max_load 150

  @doc """
  Get a page of messages for an agent. Returns `{messages_slice, total_count}`.

  Options:
    * `:limit` — max messages to return (default 50)
    * `:before_id` — load messages before this message ID (for scroll-up pagination)

  Reads directly from ETS (no GenServer call). Messages are in chronological order.
  """
  def get_messages(agent_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    before_id = Keyword.get(opts, :before_id, nil)

    case :ets.lookup(@ets_table, agent_id) do
      [{^agent_id, summary}] ->
        messages = summary.messages
        total = length(messages)

        slice =
          if before_id do
            idx = Enum.find_index(messages, &(&1[:id] == before_id)) || 0
            start = max(0, idx - limit)

            # Snap the top of the loaded chunk back to the nearest human prompt so a
            # scroll-up load always brings in COMPLETE prompt-groups — you never land
            # on a headless mid-group view missing its sticky "You" prompt. Capped at
            # @snap_max_load total so a pathologically long agent run (100s of tool
            # messages in one group) can't balloon a single load — it stays fast.
            start =
              if Keyword.get(opts, :snap_to_prompt, false) do
                floor = max(0, idx - @snap_max_load)
                snap_to_prompt_start(messages, start, floor)
              else
                start
              end

            Enum.slice(messages, start, idx - start)
          else
            Enum.take(messages, -limit)
          end

        {slice, total}

      _ ->
        {[], 0}
    end
  end

  # Nearest human (:user) prompt index in `floor..start` — the start of a group —
  # so a scroll-up load begins at a "You" instead of mid-conversation. Bounded:
  # only the `floor..start` window is scanned (≤ @snap_max_load - page_size
  # elements), and if no prompt sits in that window we stop at `floor` so the load
  # never runs away. Returns `floor` when there's nothing earlier to snap to.
  defp snap_to_prompt_start(_messages, start, floor) when start <= floor, do: floor

  defp snap_to_prompt_start(messages, start, floor) do
    window = Enum.slice(messages, floor, start - floor + 1)

    case window |> Enum.reverse() |> Enum.find_index(&(&1[:role] == :user)) do
      nil -> floor
      rev_i -> start - rev_i
    end
  end
end
