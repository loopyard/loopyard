defmodule LoopyardWeb.Live.WorkspaceLive.AgentEvents do
  @moduledoc """
  Agent PubSub event handling extracted from WorkspaceLive.

  Every function takes an event struct + socket and returns
  `{:noreply, socket}`. The WorkspaceLive `@impl` callbacks
  delegate here — they stay as one-liners in the parent module.

  The key invariant this module enforces: when updating
  `selected_agent`, ALWAYS merge ETS data (fresh counters) with
  event-driven fields (status, name, thinking_word, alive?).
  Previously this merge was copy-pasted in 3 places and each
  copy had slightly different field lists.
  """

  import Phoenix.Component, only: [assign: 2, assign: 3, update: 3]
  import Phoenix.LiveView, only: [put_flash: 3, push_patch: 2, push_event: 3]

  alias LoopyardWeb.Live.WorkspaceLive.AgentLifecycle
  alias LoopyardWeb.Components.Sidebar
  alias Loopyard.Events
  alias Loopyard.StreamBuffer

  # How far past message_window_max the window may run before pruning back
  # down to max. See the windowing comment in on_message/2.
  @window_prune_slack 40

  @doc """
  Merge ETS data with event-driven assigns for the selected agent.

  ETS has the latest counters (tokens, cost, turns) from the GenServer.
  The assigns list has the authoritative status, name, thinking_word,
  and alive? from the most recent event. Merging ensures the context
  panel shows live stats AND the correct status.

  Call this instead of `refresh_selected_agent` in event handlers.
  """
  def refresh_selected_from_agents(socket, id, agents) do
    if id == socket.assigns.selected_id do
      ets_data =
        case :ets.lookup(:chat_agents, id) do
          [{^id, data}] -> data
          _ -> %{}
        end

      case Enum.find(agents, &(&1.id == id)) do
        nil ->
          socket

        from_assigns ->
          merged =
            Map.merge(
              ets_data,
              Map.take(from_assigns, [
                :status,
                :name,
                :thinking_word,
                :alive?,
                :boot_status,
                :quarantined
              ])
            )

          assign(socket, :selected_agent, merged)
      end
    else
      socket
    end
  end

  # --- Agent lifecycle events ---

  def handle_started(%{summary: agent_summary}, socket) do
    socket =
      assign(socket, :agents, AgentLifecycle.list_workspace_agents(socket.assigns.workspace.path))

    if socket.assigns.booting_agent_id && agent_summary.id == socket.assigns.booting_agent_id do
      socket = assign(socket, :booting_agent_id, nil)

      if socket.assigns.selected_id == agent_summary.id do
        case AgentLifecycle.select_agent(socket, agent_summary.id) do
          {:noreply, s} -> {:noreply, s}
          :not_found -> {:noreply, socket}
        end
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_resumed(%{summary: summary}, socket) do
    annotated = AgentLifecycle.annotate_liveness(summary)

    agents =
      Enum.map(socket.assigns.agents, fn a ->
        if a.id == summary.id, do: annotated, else: a
      end)

    socket = assign(socket, :agents, agents)
    socket = refresh_selected_from_agents(socket, summary.id, agents)
    {:noreply, socket}
  end

  def handle_booting(%{summary: summary}, socket) do
    socket =
      assign(socket, :agents, AgentLifecycle.list_workspace_agents(socket.assigns.workspace.path))

    socket =
      if socket.assigns.selected_id == summary.id do
        assign(socket,
          booting_agent_id: summary.id,
          boot_status: summary[:boot_status] || "Initializing...",
          boot_log: []
        )
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_boot_status(%{id: id, status: status_text}, socket) do
    agents =
      Enum.map(socket.assigns.agents, fn a ->
        if a.id == id, do: Map.put(a, :boot_status, status_text), else: a
      end)

    socket = assign(socket, :agents, agents)

    socket =
      if socket.assigns.booting_agent_id == id do
        socket
        |> assign(:boot_status, status_text)
        |> update(:boot_log, &(&1 ++ [status_text]))
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_boot_failed(%{id: id, reason: reason}, socket, workspace_path_fn) do
    socket =
      assign(socket, :agents, AgentLifecycle.list_workspace_agents(socket.assigns.workspace.path))

    socket =
      if socket.assigns.booting_agent_id == id || socket.assigns.selected_id == id do
        socket
        |> assign(:booting_agent_id, nil)
        |> put_flash(:error, "Failed to start agent: #{inspect(reason)}")
        |> push_patch(to: workspace_path_fn.(socket))
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_stopped(socket) do
    agents = AgentLifecycle.list_workspace_agents(socket.assigns.workspace.path)
    socket = assign(socket, :agents, agents)
    socket = refresh_selected_from_agents(socket, socket.assigns.selected_id, agents)
    {:noreply, socket}
  end

  def handle_removed(%{id: id}, socket) do
    socket =
      assign(socket, :agents, AgentLifecycle.list_workspace_agents(socket.assigns.workspace.path))

    socket =
      if socket.assigns.selected_id == id do
        assign(socket, selected_id: nil, selected_agent: nil, messages: [])
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_renamed(%{id: id, name: new_name}, socket) do
    agents =
      Enum.map(socket.assigns.agents, fn a ->
        if a.id == id, do: %{a | name: new_name}, else: a
      end)

    socket = assign(socket, :agents, agents)
    socket = refresh_selected_from_agents(socket, id, agents)
    {:noreply, socket}
  end

  def handle_status_changed(%{id: id, status: status}, socket) do
    active_tool =
      case Enum.find(socket.assigns.agents, &(&1.id == id)) do
        %{active_tool: t} -> t
        _ -> nil
      end

    word =
      if status in [:thinking, :booting, :backoff],
        do: Sidebar.thinking_word(id, active_tool),
        else: nil

    agents =
      Enum.map(socket.assigns.agents, fn a ->
        if a.id == id do
          a
          |> Map.put(:status, status)
          |> Map.put(:thinking_word, word)
          |> AgentLifecycle.annotate_liveness()
        else
          a
        end
      end)

    socket = assign(socket, :agents, agents)
    socket = assign(socket, :thinking_word, word)
    socket = refresh_selected_from_agents(socket, id, agents)
    {:noreply, socket}
  end

  # --- Message events ---

  def handle_message(%{agent_id: id, msg: msg}, socket) when id == socket.assigns.selected_id do
    if msg[:id] && Enum.any?(socket.assigns.messages, &(&1[:id] == msg[:id])) do
      {:noreply, socket}
    else
      tool_word =
        if msg.role == :tool do
          tool = msg[:tool]
          if tool, do: Sidebar.thinking_word(id, tool)
        end

      socket =
        socket
        |> assign(:messages, socket.assigns.messages ++ [msg])
        # The finalized assistant message IS the streamed text — clear the live
        # partial (and thinking) so it stops rendering below the real message.
        # Without this the last partial sticks at the bottom AND streaming_text
        # keeps accumulating across turns into a blob the markdown renderer
        # garbles (raw HTML / stray ** leaking). Mirrors on_message (:307).
        |> then(fn s ->
          if msg.role == :assistant,
            do:
              s
              |> assign(:streaming_text, "")
              |> assign(:streaming_thinking, "")
              |> assign(:stream_md, Loopyard.Markdown.Stream.new()),
            else: s
        end)
        |> refresh_selected_from_agents(id, socket.assigns.agents)
        |> push_event("scroll_bottom", %{})

      socket =
        if tool_word do
          agents =
            Enum.map(socket.assigns.agents, fn a ->
              if a.id == id, do: Map.put(a, :thinking_word, tool_word), else: a
            end)

          socket |> assign(:agents, agents) |> assign(:thinking_word, tool_word)
        else
          socket
        end

      {:noreply, socket}
    end
  end

  def handle_message(_event, socket), do: {:noreply, socket}

  # The operator (OperatorLive) delegates its TextDelta here. Unified onto
  # on_text_delta so BOTH chats stream through the one Markdown.Stream path — the
  # old divergent body ("replace streaming_text with the chunk, don't push to the
  # client") is gone; it's what made the operator stream differently.
  def handle_text_delta(e, socket), do: on_text_delta(e, socket)

  # --- ChatAgentMessage subscriber bodies (WorkspaceLive delegates here) ---

  def on_message(%Events.ChatAgentMessage.Message{agent_id: id, msg: msg}, socket)
      when id == socket.assigns.selected_id do
    cond do
      # Guard against duplicate messages (mobile reconnect → double PubSub subs).
      msg[:id] && Enum.any?(socket.assigns.messages, &(&1[:id] == msg[:id])) ->
        {:noreply, socket}

      # Viewing history — the window no longer follows the live tail, so DON'T
      # grow it (that's the whole point of windowing). The "Jump to latest" pill
      # (shown whenever the window isn't the tail) is how you catch up. Keep the
      # cockpit fresh so status / recent still update while you read.
      not socket.assigns.window_tail? ->
        {:noreply, refresh_selected_from_agents(socket, id, socket.assigns.agents)}

      true ->
        socket =
          if msg.role == :assistant,
            do:
              socket
              |> assign(:streaming_text, "")
              |> assign(:streaming_thinking, "")
              |> assign(:stream_md, Loopyard.Markdown.Stream.new()),
            else: socket

        # If build was running and we get a post-build message, mark build as done
        socket =
          if socket.assigns.building && msg.role in [:system, :error] do
            messages =
              Enum.map(socket.assigns.messages, fn
                %{role: :build} = m -> %{m | role: :build_done}
                other -> other
              end)

            socket |> assign(:messages, messages) |> assign(:building, false)
          else
            socket
          end

        # Append to the tail window, then CAP the DOM: drop from the top once we
        # exceed the max. The dropped rows are above the viewport (you're at the
        # bottom following the stream), so the browser's scroll anchoring keeps
        # the visible content put — no shift. Dropping the top means older
        # messages now live off-window, so re-enable "load older".
        #
        # Pruned in CHUNKS, not one-per-append: dropping exactly one from the
        # top on every append shifts EVERY row's position, and the keyed
        # transcript then ships a move record per row per append (~87KB/append
        # measured at the cap). Letting the window run @window_prune_slack over
        # and dropping the whole overhang at once makes the other appends pure
        # appends — zero shifts.
        max = AgentLifecycle.message_window_max()
        appended = socket.assigns.messages ++ [msg]

        {windowed, dropped_top?} =
          if length(appended) > max + @window_prune_slack,
            do: {Enum.take(appended, -max), true},
            else: {appended, false}

        socket =
          socket
          |> assign(:messages, windowed)
          |> assign(:has_more_messages, socket.assigns.has_more_messages || dropped_top?)
          |> refresh_selected_from_agents(id, socket.assigns.agents)
          |> push_event("scroll_bottom", %{})

        # Update thinking word when a tool message arrives — shows the
        # tool-specific phrase (e.g., "grepping" instead of "pondering")
        socket =
          if msg.role == :tool && socket.assigns.selected_agent &&
               socket.assigns.selected_agent.status == :thinking do
            tool = msg[:tool]
            word = LoopyardWeb.Components.Sidebar.thinking_word(id, tool)
            assign(socket, :thinking_word, word)
          else
            socket
          end

        {:noreply, socket}
    end
  end

  def on_message(%Events.ChatAgentMessage.Message{}, socket), do: {:noreply, socket}

  # An existing message changed in place (question answered, approval resolved,
  # partial finalized). Replace it by id — no append, no scroll, no window
  # growth. If the message is above the window (older than the tail) this is a
  # no-op; a reload shows the persisted state.
  def on_message_updated(%Events.ChatAgentMessage.MessageUpdated{agent_id: id, msg: msg}, socket)
      when id == socket.assigns.selected_id do
    if msg[:id] && Enum.any?(socket.assigns.messages, &(&1[:id] == msg[:id])) do
      messages =
        Enum.map(socket.assigns.messages, fn m ->
          if m[:id] == msg[:id], do: msg, else: m
        end)

      {:noreply, assign(socket, :messages, messages)}
    else
      {:noreply, socket}
    end
  end

  def on_message_updated(%Events.ChatAgentMessage.MessageUpdated{}, socket),
    do: {:noreply, socket}

  def on_text_delta(%Events.ChatAgentMessage.TextDelta{agent_id: id, text: text}, socket)
      when id == socket.assigns.selected_id do
    # ONLY touch streaming state on a token. Do NOT rebuild @selected_agent here
    # (that re-rendered the entire cockpit on every token — the flicker/CPU
    # source). The context panel refreshes on Message / StatusChanged.
    #
    # Feed the raw chunk into the per-connection markdown streamer: it emits
    # COMPLETE blocks as safe HTML (append-only, the StreamMarkdown hook appends
    # each once) plus the current incomplete block as a plain tail. No partial
    # markdown ever reaches the DOM, and nothing re-diffs the growing reply.
    # `streaming_text` is still accumulated for the token counter + bubble :if.
    stream_md = socket.assigns[:stream_md] || Loopyard.Markdown.Stream.new()
    {stream_md, html, tail} = Loopyard.Markdown.Stream.feed(stream_md, text)

    {:noreply,
     socket
     |> assign(:streaming_text, socket.assigns.streaming_text <> text)
     |> assign(:stream_md, stream_md)
     |> assign(:streaming_thinking, "")
     |> push_event("stream_html", %{html: html, tail: tail})
     |> push_event("scroll_bottom", %{})}
  end

  def on_text_delta(%Events.ChatAgentMessage.TextDelta{}, socket), do: {:noreply, socket}

  def on_stream_output(
        %Events.ChatAgentMessage.StreamOutput{
          agent_id: id,
          data: data,
          title: "__thinking__"
        },
        socket
      )
      when id == socket.assigns.selected_id do
    {:noreply,
     socket
     |> assign(:streaming_thinking, (socket.assigns[:streaming_thinking] || "") <> data)
     |> push_event("stream_thinking_delta", %{text: data})
     |> push_event("scroll_bottom", %{})}
  end

  def on_stream_output(
        %Events.ChatAgentMessage.StreamOutput{
          agent_id: id,
          data: data,
          title: title,
          msg_id: msg_id
        },
        socket
      )
      when id == socket.assigns.selected_id do
    upsert_stream_message(socket, data, title, msg_id)
  end

  def on_stream_output(%Events.ChatAgentMessage.StreamOutput{}, socket), do: {:noreply, socket}

  # Shared by on_stream_output AND WorkspaceLive's docker-build stream path.
  # COALESCED: appending to the buffer is cheap (not rendered); the expensive
  # @messages upsert + transcript re-diff runs at most every 150ms via the
  # :flush_stream_buffer tick (see flush_stream_buffer/1). Per-chunk upserts
  # re-diffed the whole transcript for every line of command output —
  # saturating the LV so taps/clicks queued for seconds behind the backlog.
  def upsert_stream_message(socket, data, title, msg_id) do
    stream_buffer =
      socket.assigns.stream_buffer
      |> StreamBuffer.append(data, title: title, msg_id: msg_id)

    socket =
      socket
      |> assign(:stream_buffer, stream_buffer)
      |> assign(:building, true)

    if socket.assigns[:stream_flush_armed] do
      {:noreply, socket}
    else
      Process.send_after(self(), :flush_stream_buffer, 150)
      {:noreply, assign(socket, :stream_flush_armed, true)}
    end
  end

  @doc "The 150ms flush: apply the buffered stream chunks to @messages once."
  def flush_stream_buffer(socket) do
    messages = StreamBuffer.upsert_message(socket.assigns.stream_buffer, socket.assigns.messages)

    {:noreply,
     socket
     |> assign(:messages, messages)
     |> assign(:stream_flush_armed, false)
     |> Phoenix.LiveView.push_event("scroll_bottom", %{})}
  end
end
