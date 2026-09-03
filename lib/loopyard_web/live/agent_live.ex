defmodule LoopyardWeb.AgentLive do
  @moduledoc """
  `/agents/:id` — one agent's chat, standalone (no workspace chrome). The
  page for any SYSTEM agent (the operator and its peers): an in-container
  ACP agent bound to a workstation identity, with no workspace/project, so
  it can't render through the workspace view. A WORKSPACE agent's id here
  redirects to its workspace chat, which has the chrome that agent needs.

  `/operator` redirects here, to the identity's default system agent
  (`Loopyard.Agents.ensure_default/0` creates it on first visit).

  **Same rendering mechanisms as the workspace chat.** We deliberately reuse the
  extracted handlers (`AgentEvents.handle_message/handle_text_delta/
  handle_status_changed`) and the shared `StreamBuffer` rather than re-fetching
  the whole transcript on every event. That means: incremental append + dedup on
  new messages, live token streaming, and streamed tool/exec output — the exact
  efficient path the workspace built. To use those handlers we adopt their assign
  contract (`selected_id`, `agents`, `selected_agent`, `messages`,
  `streaming_text`, `streaming_thinking`, `stream_buffer`, …), flattening one
  agent into the same shape as a one-agent workspace.

  The "for you" rail that used to sit beside the operator's chat is gone: what
  it listed lives on `/notifications`; the sound player is the bar's pill.
  """
  use LoopyardWeb, :live_view

  alias Loopyard.{Agents, ChatAgent, StreamBuffer}
  alias Loopyard.Events
  alias LoopyardWeb.Live.WorkspaceLive.AgentEvents
  alias LoopyardWeb.Components.{AppShell, Common}
  import LoopyardWeb.Live.WorkspaceLive.Components.Chat, only: [chat_panel: 1]

  alias LoopyardWeb.Live.WorkspaceLive.Attachments, as: ComposerAttachments

  # Recent-tail size for the chat transcript. Caps the initial LiveView payload
  # so a long-lived agent's history can't blow the WebSocket join frame.
  @message_window 80
  # Hard cap on messages held in the DOM. Scrolling up pages older ones in; once
  # the window overflows this, the live tail is dropped (off-screen anyway) so the
  # DOM never holds the whole history. "Jump to latest" reloads the tail.
  @message_window_max 240

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Agents.get(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "No agent with that id.")
         |> push_navigate(to: "/")}

      %{workspace_id: ws} = summary when is_binary(ws) ->
        # A workspace agent lives in its workspace's chat (services, files,
        # ports are its chrome); send the visitor there.
        {:ok, push_navigate(socket, to: workspace_chat_path(summary))}

      summary ->
        {:ok, mount_agent(socket, id, summary)}
    end
  end

  defp mount_agent(socket, id, summary) do
    # NEVER wake an agent synchronously here: ensuring its workstation
    # CONTAINER can take seconds to minutes cold, and mount must render
    # instantly. Fast path: it's alive → nothing to do. Cold path: render now,
    # wake in start_async, wire up when it lands (harness-status shows
    # "Starting" meanwhile).
    if connected?(socket) do
      Events.ChatAgentMessage.subscribe(id)
      Events.ChatAgent.subscribe()
      # `music` play/pause/volume commands → bridged to this client's
      # AmbientAudio engine (server-side track/status don't need this).
      Events.Aural.subscribe()
    end

    host =
      case socket.host_uri do
        %URI{host: h} when is_binary(h) and h != "" -> h
        _ -> "localhost"
      end

    socket =
      socket
      |> assign(:agent_id, id)
      |> assign(:agent_name, summary[:name] || "Agent")
      # Chat attachments live wherever this agent's compute is (its
      # workstation container for a system agent).
      |> ComposerAttachments.allow()
      |> assign(
        :attachment_target,
        Agents.attachment_target(id) || Agents.default_attachment_target()
      )
      # The shared chat handlers key everything off :selected_id — this one
      # agent IS the selection.
      |> assign(:selected_id, id)
      |> assign(:host, host)
      |> assign(:streaming_text, "")
      |> assign(:stream_md, Loopyard.Markdown.Stream.new())
      |> assign(:streaming_thinking, "")
      |> assign(:stream_buffer, StreamBuffer.new())
      |> assign(:building, false)
      |> assign(:thinking_word, nil)
      |> assign(:has_more_messages, false)
      |> assign(:window_tail?, true)
      |> load_agent()
      # The shared consent surface: question + secret cards answer through the
      # SAME hook as the workspace chat. A system agent's secrets scope to its
      # identity (no workspace).
      |> LoopyardWeb.Live.ConsentUI.attach(secret_scope: summary[:workspace_id])
      # Subscribe to the sub-agents this agent is embedding, so their live
      # windows update as they work.
      |> assign(:embedded_ids, MapSet.new())
      |> subscribe_embeds()

    if connected?(socket) and not Agents.alive?(id) do
      Phoenix.LiveView.start_async(socket, :ensure_agent, fn -> Agents.ensure_running(id) end)
    else
      socket
    end
  end

  defp workspace_chat_path(%{workspace_id: ws, id: id}) do
    case Loopyard.WorkspaceRegistry.get_workspace(ws) do
      %{project_id: pid} when is_binary(pid) -> "/projects/#{pid}/workspaces/#{ws}/agents/#{id}"
      _ -> "/workspaces"
    end
  end

  @impl true
  def handle_async(:ensure_agent, {:ok, :ok}, socket) do
    {:noreply, load_agent(socket)}
  end

  def handle_async(:ensure_agent, result, socket) do
    Loopyard.EventLog.error(
      "agent:#{socket.assigns.agent_name}",
      "wake failed: #{inspect(result, limit: 5)}"
    )

    {:noreply,
     Phoenix.LiveView.put_flash(
       socket,
       :error,
       "#{socket.assigns.agent_name} couldn't start — check the workstation container on /system."
     )}
  end

  # The sub-agents referenced by :embed cards in the transcript. Subscribe to any
  # newly-referenced one; the subscription is idempotent per LV (we track which).
  defp subscribe_embeds(socket) do
    ids =
      socket.assigns.messages
      |> Enum.filter(&(&1[:role] == :embed and is_binary(&1[:agent_id])))
      |> MapSet.new(& &1.agent_id)

    if connected?(socket) do
      MapSet.difference(ids, socket.assigns.embedded_ids)
      |> Enum.each(&Events.ChatAgentMessage.subscribe/1)
    end

    assign(socket, :embedded_ids, ids)
  end

  # Force a specific embed card to re-render (re-read the sub-agent's state) by
  # touching its message — the ONLY reliable way past LiveView's component
  # memoization. Never mixes the sub-agent's content into this agent's chat.
  defp touch_embed(socket, agent_id) do
    messages =
      Enum.map(socket.assigns.messages, fn m ->
        if m[:role] == :embed and m[:agent_id] == agent_id,
          do: Map.put(m, :tick, (m[:tick] || 0) + 1),
          else: m
      end)

    assign(socket, :messages, messages)
  end

  # Load the agent summary + transcript into the workspace-chat assign shape:
  # `agents` is a one-element list so `AgentEvents.refresh_selected_from_agents`
  # (ETS-counter merge) finds it. Used at mount + after an approval decision (the
  # one message-*update* path with no incremental event to ride).
  defp load_agent(socket) do
    case ChatAgent.get_state(socket.assigns.agent_id) do
      %{} = st ->
        all = st.messages || []
        # WINDOW the transcript: a long-lived agent accumulates hundreds of
        # turns, and rendering all of them blew the WebSocket join frame.
        windowed = Enum.take(all, -@message_window)

        socket
        |> assign(:selected_agent, st)
        |> assign(:agent_name, st[:name] || socket.assigns.agent_name)
        |> assign(:agents, [st])
        |> assign(:messages, windowed)
        |> assign(:has_more_messages, length(all) > length(windowed))

      _ ->
        stub = %{id: socket.assigns.agent_id, status: :idle}

        socket
        |> assign(:selected_agent, stub)
        |> assign(:agents, [stub])
        |> assign(:messages, [])
    end
  end

  @impl true
  def handle_event("send_message", %{"message" => message}, socket) do
    # Drop empty / whitespace-only sends so the agent never gets a blank prompt.
    # Still ack so the ChatForm hook clears the box.
    message = String.trim(message)
    editing = socket.assigns[:editing_pending]
    attachments? = ComposerAttachments.pending?(socket)
    name = socket.assigns.agent_name

    cond do
      # EDIT-IN-PLACE: save an edited queued message at its position instead of
      # re-appending (which reordered the queue). Empty box = cancel, untouched.
      match?(%{index: _}, editing) ->
        %{index: idx, text: old} = editing

        if message != "",
          do:
            ChatAgent.update_pending(
              socket.assigns.agent_id,
              idx,
              old,
              Loopyard.Attachments.annotate(message, elem(Loopyard.Attachments.parse(old), 1))
            )

        {:reply, %{ok: true}, assign(socket, :editing_pending, nil)}

      message == "" and not attachments? ->
        {:reply, %{ok: true}, socket}

      true ->
        # DURABILITY-CONFIRMED, same contract as the workspace composer: a call,
        # because only a call can tell the person their text landed.
        with {:ok, socket, atts} <- ComposerAttachments.consume(socket),
             :ok <-
               ChatAgent.enqueue_message(
                 socket.assigns.agent_id,
                 Loopyard.Attachments.annotate(message, atts)
               ) do
          {:reply, %{ok: true}, socket}
        else
          {:error, %Phoenix.LiveView.Socket{} = socket, note} ->
            {:reply, %{ok: false, note: note}, socket}

          {:error, :queue_full} ->
            {:reply,
             %{
               ok: false,
               note: "#{name}'s queue is full — your text is kept. Try again shortly."
             }, socket}

          {:error, _} ->
            {:reply,
             %{
               ok: false,
               note: "#{name} didn't take that — your text is kept. Try again in a moment."
             }, socket}
        end
    end
  end

  # Composer/queue controls (chat_panel emits these) — wired so no button is dead.
  # The composer's upload tray (see WorkspaceLive.Attachments).
  def handle_event("validate_attachments", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_attachment", %{"ref" => ref}, socket),
    do: {:noreply, ComposerAttachments.cancel(socket, ref)}

  def handle_event("clear_pending", _p, socket) do
    ChatAgent.clear_pending(socket.assigns.agent_id)
    {:noreply, assign(socket, :editing_pending, nil)}
  end

  def handle_event("remove_pending", %{"id" => id, "index" => index}, socket) do
    ChatAgent.remove_pending(id, String.to_integer(index))
    {:noreply, socket}
  end

  def handle_event("edit_pending", %{"id" => _id, "index" => index}, socket) do
    # Edit-in-place: remember position (index + original text) and fill the box;
    # saving replaces it there instead of re-appending. Not removed here, so
    # cancelling leaves the queue untouched.
    index = String.to_integer(index)
    text = Enum.at(socket.assigns.selected_agent[:pending_messages] || [], index)

    if is_binary(text),
      do: {:noreply, edit_fill(socket, index, text)},
      else: {:noreply, socket}
  end

  def handle_event("interrupt_agent", %{"id" => id}, socket) do
    ChatAgent.interrupt(id)
    {:noreply, socket}
  end

  # Approve/Deny on the approval "chat mini app" — the interactive half of the
  # create-project flow. Delivers the decision to the blocked ControlPlane tool
  # (which then fires Onboarding + spawns the workspace agent).
  def handle_event("decide_approval", %{"approval_id" => id, "decision" => decision}, socket) do
    decision = if decision == "approve", do: :approve, else: :deny
    agent_id = socket.assigns.agent_id
    card = Enum.find(socket.assigns.messages, &(&1[:approval_id] == id))

    # Optimistic flip so the buttons don't sit unclicked while the action runs —
    # but the transient must MATCH the verb (a rename is not "Creating the branch
    # workspace"; that misleading text made a harmless rename look destructive).
    if decision == :approve and card do
      transient =
        case card[:action][:verb] do
          v when v in [:delete_workspace, :delete_project] -> :deleting
          v when v in [:rename_workspace, :rename_project] -> :renaming
          :integrate -> :integrating
          _ -> :creating
        end

      ChatAgent.update_message(agent_id, card.id, &Map.put(&1, :status, transient))
    end

    case Loopyard.Harness.Approvals.decide(id, decision) do
      :ok ->
        :ok

      {:error, :not_found} ->
        if card do
          ChatAgent.update_message(agent_id, card.id, fn m ->
            Map.merge(m, %{status: :failed, error: "this proposal expired — ask again"})
          end)
        end
    end

    # A message *field* update (not a new message) has no incremental event to
    # ride, so re-sync the transcript here. Rare (a button click), unlike the
    # streaming hot path which stays incremental.
    {:noreply, load_agent(socket)}
  end

  # PerfProbe (chat_panel's client-health beacon) reports here — without this
  # clause every jank sample CRASHED the LiveView it was reporting on
  # (FunctionClauseError → remount), which read as "the app feels unreliable".
  def handle_event("perf_sample", sample, socket) when is_map(sample) do
    max_gap = sample["max_gap_ms"]

    if is_number(max_gap) and max_gap > 100 do
      Loopyard.EventLog.warning(
        "perf",
        "client jank: max_gap=#{max_gap}ms over50=#{sample["gaps_over_50"]} " <>
          "dom=#{sample["dom"]} heap=#{sample["heap_mb"]}MB agent=#{socket.assigns.agent_id}"
      )
    end

    {:noreply, socket}
  end

  # Scroll-up paging: the ScrollBottom hook fires this near the top. Prepend the
  # next older batch from the durable log, capped at @message_window_max so the
  # DOM never holds the whole history — on overflow we drop from the TAIL (it's
  # off-screen while you read up here), which stops the window following the live
  # stream until "jump to latest" (load_latest) snaps back.
  def handle_event("load_more", _params, socket) do
    if socket.assigns.has_more_messages && socket.assigns.selected_id do
      oldest = List.first(socket.assigns.messages)

      {older, _total} =
        ChatAgent.get_messages(socket.assigns.selected_id,
          limit: @message_window,
          before_id: oldest && oldest[:id],
          snap_to_prompt: true
        )

      if older != [] do
        combined = older ++ socket.assigns.messages

        {windowed, tail?} =
          if length(combined) > @message_window_max do
            {Enum.take(combined, @message_window_max), false}
          else
            {combined, socket.assigns.window_tail?}
          end

        {:noreply,
         socket
         |> assign(:messages, windowed)
         |> assign(:has_more_messages, true)
         |> assign(:window_tail?, tail?)}
      else
        {:noreply, assign(socket, :has_more_messages, false)}
      end
    else
      {:noreply, socket}
    end
  end

  # Jump back to the live tail after scrolling up past the DOM cap: reload the
  # last window from the agent and snap to the bottom.
  def handle_event("load_latest", _params, socket) do
    case socket.assigns.selected_id do
      nil ->
        {:noreply, socket}

      id ->
        all = (ChatAgent.get_state(id) || %{})[:messages] || []
        page = Enum.take(all, -@message_window)

        {:noreply,
         socket
         |> assign(:messages, page)
         |> assign(:has_more_messages, length(page) < length(all))
         |> assign(:window_tail?, true)
         |> push_event("jump_bottom", %{})}
    end
  end

  def handle_event(_evt, _params, socket), do: {:noreply, socket}

  # Explicit push_event(socket, ...) form: the composer-writes guardrail counts
  # that shape to prove every fill_input comes from a human action.
  defp edit_fill(socket, index, text) do
    # The box gets the human's words; attachments stay pinned to the queued
    # line and are re-attached on save.
    {body, _atts} = Loopyard.Attachments.parse(text)
    socket = assign(socket, :editing_pending, %{index: index, text: text})
    push_event(socket, "fill_input", %{text: body})
  end

  # --- Message + streaming events: delegate to the SAME handlers the workspace
  # chat uses, so this agent gets incremental append + live streaming. ---

  @impl true
  def handle_info(%Events.ChatAgentMessage.Message{agent_id: id} = e, socket) do
    cond do
      id == socket.assigns.agent_id ->
        # This agent's own message → normal chat handling. A new :embed card may
        # reference a new sub-agent, so re-check subscriptions.
        {:noreply, socket} = AgentEvents.handle_message(e, socket)
        {:noreply, subscribe_embeds(socket)}

      MapSet.member?(socket.assigns.embedded_ids, id) ->
        # A sub-agent we embed produced a message → refresh its live window ONLY;
        # never fold a sub-agent's content into this transcript.
        {:noreply, touch_embed(socket, id)}

      true ->
        {:noreply, socket}
    end
  end

  # Card status resolutions (approval → :renamed / :deleted / :approved / progress)
  # ride MessageUpdated. Without this the cards freeze at their optimistic
  # status and never show the outcome (the "stuck Creating…" bug).
  def handle_info(%Events.ChatAgentMessage.MessageUpdated{} = e, socket),
    do: AgentEvents.on_message_updated(e, socket)

  def handle_info(%Events.ChatAgentMessage.TextDelta{} = e, socket),
    do: AgentEvents.handle_text_delta(e, socket)

  # Ambient play/pause/volume command from the `music` tool → push to this
  # client's AmbientAudio engine (which applies it; the sound pill reflects).
  def handle_info(%Events.Aural.Command{action: action, value: value}, socket),
    do:
      {:noreply, push_event(socket, "aural_command", %{action: to_string(action), value: value})}

  # Streamed model reasoning → the thinking bubble.
  def handle_info(
        %Events.ChatAgentMessage.StreamOutput{agent_id: id, data: data, title: "__thinking__"},
        socket
      )
      when id == socket.assigns.selected_id do
    {:noreply,
     socket
     |> assign(:streaming_thinking, (socket.assigns[:streaming_thinking] || "") <> data)
     |> push_event("scroll_bottom", %{})}
  end

  # Streamed tool/exec output → upsert one build message via the shared StreamBuffer.
  def handle_info(
        %Events.ChatAgentMessage.StreamOutput{
          agent_id: id,
          data: data,
          title: title,
          msg_id: msg_id
        },
        socket
      )
      when id == socket.assigns.selected_id do
    AgentEvents.upsert_stream_message(socket, data, title, msg_id)
  end

  @impl true
  def handle_info(:flush_stream_buffer, socket), do: AgentEvents.flush_stream_buffer(socket)

  def handle_info(%Events.ChatAgentMessage.StreamOutput{}, socket), do: {:noreply, socket}

  def handle_info(%Events.ChatAgent.StatusChanged{} = e, socket) do
    {:noreply, socket} = AgentEvents.handle_status_changed(e, socket)

    # If it's an agent we embed, refresh its live window too (working → ready).
    socket =
      if MapSet.member?(socket.assigns.embedded_ids, e.id),
        do: touch_embed(socket, e.id),
        else: socket

    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # The row under the bar: what it's doing, what it runs on, how full its
  # window is. Facts only — the transcript carries the narrative.
  defp status_line(agent) do
    [
      Common.status_word(agent_state(agent)),
      Loopyard.Harness.Catalog.label(agent[:harness]),
      agent[:model],
      context_pct(agent[:context_utilization])
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  defp context_pct(u) when is_number(u) and u > 0.0, do: "#{round(u * 100)}% ctx"
  defp context_pct(_), do: nil

  defp agent_state(agent) do
    case agent[:status] do
      s when s in [:thinking, :backoff, :compacting, :booting, :starting, :restarting] -> :working
      :auth_expired -> :broken
      :idle -> :done
      _ -> :asleep
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <AppShell.shell
      title={@agent_name}
      mode={:agents}
      mode_id="mode-agent"
      id="agent-page"
      phx-hook="ScrollBottom"
    >
      <%!-- WHAT THIS AGENT IS DOING, always on screen. A workspace agent says
      this in its sidebar; here there is no sidebar, so without this the only
      statement of state was a line in the transcript that scrolls away. --%>
      <:status>
        <span
          class={["flex-none w-2 h-2 rounded-full", Common.state_light(agent_state(@selected_agent))]}
          aria-hidden="true"
        ></span>
        <span class="flex-none font-medium text-zinc-900 dark:text-zinc-50 truncate">
          {@agent_name}
        </span>
        <span class="min-w-0 truncate text-meta text-zinc-500 dark:text-zinc-400">
          {status_line(@selected_agent)}
        </span>
      </:status>
      <div class="flex-1 min-w-0 flex flex-col min-h-0">
        <.chat_panel
          messages={@messages}
          streaming_text={@streaming_text}
          streaming_thinking={@streaming_thinking}
          agent={@selected_agent}
          uploads={assigns[:uploads]}
          workspace_id={nil}
          host={@host}
          thinking_word={@thinking_word || "Thinking"}
          has_more_messages={@has_more_messages}
          window_tail?={@window_tail?}
          detail_level={:chat}
        />
      </div>
    </AppShell.shell>
    """
  end
end
