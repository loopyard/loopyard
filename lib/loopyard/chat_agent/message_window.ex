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

  # ---- ETS-path message WRITES (callers outside the GenServer) ----
  # Moved from ChatAgent (module-size invariant); ChatAgent defdelegates here.

  @doc """
  Append a message to an agent's message list (for stream messages created
  outside the GenServer). Goes through the GenServer if alive, falls back to
  direct ETS write.
  """
  def append_message_ets(agent_id, msg) do
    msg = Map.put_new_lazy(msg, :id, fn -> generate_msg_id() end)

    appended =
      case Registry.lookup(Loopyard.ChatAgentRegistry, agent_id) do
        [{pid, _}] ->
          GenServer.cast(pid, {:append_external_message, msg})
          msg

        [] ->
          # No GenServer running — direct ETS write
          case :ets.lookup(@ets_table, agent_id) do
            [{^agent_id, summary}] ->
              :ets.insert(
                @ets_table,
                {agent_id, %{summary | messages: summary.messages ++ [msg]}}
              )

              msg

            [] ->
              nil
          end
      end

    # THE FUNNEL: every decision card (question / approval / secret request)
    # enters the transcript here, so this is where the inbox learns of it.
    # A cast — the append path never blocks on the store.
    if appended, do: Loopyard.Notifications.card_raised(agent_id, msg)
    appended
  end

  @doc "Update a message by ID. Goes through GenServer if alive, falls back to direct ETS."
  def update_message(agent_id, msg_id, update_fn) do
    case Registry.lookup(Loopyard.ChatAgentRegistry, agent_id) do
      [{pid, _}] ->
        GenServer.cast(pid, {:update_message, msg_id, update_fn})
        :ok

      [] ->
        patch_ets_and_broadcast(agent_id, msg_id, update_fn)
    end
  end

  @doc """
  Update a message NOW: patch ETS + broadcast immediately, then let the live
  GenServer (if any) converge via the normal cast.

  For CARD-STATE changes (question drafts/selections/locks) — pure
  `Map.merge`s that don't depend on GenServer state. The plain
  `update_message/3` cast rides the agent's mailbox, which during a streaming
  turn sits behind a backlog of token events — tapping an option on a busy
  agent's card took SECONDS to highlight. Every viewer reads the patched ETS
  + broadcast instantly; the cast re-applies the same merge (idempotent) so
  the GenServer's own state catches up.
  """
  def update_message_now(agent_id, msg_id, changes) when is_map(changes) do
    # Monotonic version so a stale state can never win over this patch.
    changes = Map.put(changes, :card_v, System.monotonic_time())

    # Record FIRST: any summary write racing us re-applies via
    # reconcile_card_patches, so the interaction can't be clobbered.
    :ets.insert(:card_patches, {{agent_id, msg_id}, changes})

    result = patch_ets_and_broadcast(agent_id, msg_id, &Map.merge(&1, changes))

    # THE OTHER FUNNEL: a card's status flip (answered / approved / submitted /
    # declined / timeout) settles its inbox item. Also a cast.
    if Map.has_key?(changes, :status),
      do: Loopyard.Notifications.card_status(agent_id, msg_id, changes.status)

    case Registry.lookup(Loopyard.ChatAgentRegistry, agent_id) do
      [{pid, _}] ->
        GenServer.cast(pid, {:card_patch, msg_id, changes})

      [] ->
        # No GenServer to converge — the patch was applied to ETS directly;
        # drop the record so the table stays tiny.
        :ets.delete(:card_patches, {agent_id, msg_id})
    end

    result
  end

  defp patch_ets_and_broadcast(agent_id, msg_id, update_fn) do
    case :ets.lookup(@ets_table, agent_id) do
      [{^agent_id, summary}] ->
        try do
          messages =
            Enum.map(summary.messages, fn msg ->
              if msg[:id] == msg_id, do: update_fn.(msg), else: msg
            end)

          :ets.insert(@ets_table, {agent_id, %{summary | messages: messages}})

          # Same live-patch broadcast as the GenServer path — a viewer
          # watching a stopped agent's transcript still sees the update.
          case Enum.find(messages, &(&1[:id] == msg_id)) do
            nil ->
              :ok

            new_msg ->
              Loopyard.Events.ChatAgentMessage.publish(
                %Loopyard.Events.ChatAgentMessage.MessageUpdated{
                  agent_id: agent_id,
                  msg: new_msg
                }
              )
          end

          :ok
        rescue
          e ->
            :telemetry.execute(
              [:loopyard, :agent, :update_message_failed],
              %{count: 1},
              %{agent_id: agent_id, msg_id: msg_id, reason: Exception.message(e)}
            )

            :error
        end
    end
  end

  defp generate_msg_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end
end
