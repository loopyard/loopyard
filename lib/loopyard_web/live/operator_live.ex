defmodule LoopyardWeb.OperatorLive do
  @moduledoc """
  `/operator` — the operator agent's own chat, standalone (no workspace chrome).
  The operator is an in-container ACP agent (its own workstation container) with
  no workspace/project, so it can't render through the workspace view — it gets
  its own focused screen:
  a header + the shared `chat_panel`. Created on first visit
  (`Loopyard.Operator.ensure_agent/0`).

  **Same rendering mechanisms as the workspace chat.** We deliberately reuse the
  extracted handlers (`AgentEvents.handle_message/handle_text_delta/
  handle_status_changed`) and the shared `StreamBuffer` rather than re-fetching
  the whole transcript on every event. That means: incremental append + dedup on
  new messages, live token streaming, and streamed tool/exec output — the exact
  efficient path the workspace built. To use those handlers we adopt their assign
  contract (`selected_id`, `agents`, `selected_agent`, `messages`,
  `streaming_text`, `streaming_thinking`, `stream_buffer`, …), flattening the
  operator's single agent into the same shape as a one-agent workspace.
  """
  use LoopyardWeb, :live_view

  alias Loopyard.{ChatAgent, Operator, StreamBuffer}
  alias Loopyard.Events
  alias LoopyardWeb.Components.Nav
  alias LoopyardWeb.Live.WorkspaceLive.AgentEvents
  import LoopyardWeb.Components.Breadcrumbs, only: [breadcrumbs: 1]
  import LoopyardWeb.Live.WorkspaceLive.Components.Chat, only: [chat_panel: 1]

  @impl true
  def mount(_params, _session, socket) do
    {:ok, %{agent_id: agent_id}} = Operator.ensure_agent()

    if connected?(socket) do
      Events.ChatAgentMessage.subscribe(agent_id)
      Events.ChatAgent.subscribe()
      # Operator `music` play/pause/volume commands → bridged to this client's
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
      |> assign(:agent_id, agent_id)
      # The shared chat handlers key everything off :selected_id — the operator's
      # single agent IS the selection.
      |> assign(:selected_id, agent_id)
      |> assign(:host, host)
      |> assign(:streaming_text, "")
      |> assign(:streaming_thinking, "")
      |> assign(:stream_buffer, StreamBuffer.new())
      |> assign(:building, false)
      |> assign(:thinking_word, nil)
      |> assign(:restored_failed_prompt, nil)
      # No windowing for the operator's short chats — the whole transcript is the
      # tail. (chat_panel still reads these two.)
      |> assign(:has_more_messages, false)
      |> assign(:window_tail?, true)
      # The attention queue — every active project/workspace + what it needs.
      # Refreshed on any agent's status change (below). ETS-cheap.
      |> assign(:tree, Loopyard.WorkspaceTree.global(host))
      # "Needs you" = the town-hall blocking-item count (questions/secrets/
      # approvals across all agents), refreshed on any status change.
      |> assign(:needs_you_count, Loopyard.Attention.count(host))
      |> load_agent()
      # The shared consent surface: question + secret cards answer through the
      # SAME hook as the workspace chat, so the operator stream is never missing
      # a consent feature. No workspace → secrets scope to nil.
      |> LoopyardWeb.Live.ConsentUI.attach(secret_scope: nil)

    {:ok, socket}
  end

  # Load the agent summary + transcript into the workspace-chat assign shape:
  # `agents` is a one-element list so `AgentEvents.refresh_selected_from_agents`
  # (ETS-counter merge) finds it. Used at mount + after an approval decision (the
  # one message-*update* path with no incremental event to ride).
  defp load_agent(socket) do
    case ChatAgent.get_state(socket.assigns.agent_id) do
      %{} = st ->
        socket
        |> assign(:selected_agent, st)
        |> assign(:agents, [st])
        |> assign(:messages, st.messages)

      _ ->
        stub = %{id: socket.assigns.agent_id, status: :idle}
        socket |> assign(:selected_agent, stub) |> assign(:agents, [stub]) |> assign(:messages, [])
    end
  end

  @impl true
  def handle_event("send_message", %{"message" => message}, socket) do
    # Drop empty / whitespace-only sends so the operator never gets a blank prompt
    # (which makes it reply "your message came through empty"). Still ack so the
    # ChatForm hook clears the box.
    message = String.trim(message)
    if message != "", do: ChatAgent.send_message(socket.assigns.agent_id, message)
    {:reply, %{ok: true}, socket}
  end

  # Composer/queue controls (chat_panel emits these) — wired so no button is dead.
  def handle_event("clear_pending", _p, socket) do
    ChatAgent.clear_pending(socket.assigns.agent_id)
    {:noreply, socket}
  end

  def handle_event("remove_pending", %{"id" => id, "index" => index}, socket) do
    ChatAgent.remove_pending(id, String.to_integer(index))
    {:noreply, socket}
  end

  def handle_event("edit_pending", %{"id" => id, "index" => index}, socket) do
    index = String.to_integer(index)
    text = Enum.at(socket.assigns.selected_agent[:pending_messages] || [], index)
    ChatAgent.remove_pending(id, index)

    if is_binary(text),
      do: {:noreply, push_event(socket, "fill_input", %{text: text})},
      else: {:noreply, socket}
  end

  def handle_event("interrupt_agent", %{"id" => id}, socket) do
    ChatAgent.interrupt(id)
    {:noreply, socket}
  end

  # Approve/Deny on the approval "chat mini app" — the interactive half of the
  # create-project flow. Delivers the decision to the blocked ControlPlane tool
  # (which then fires Onboarding + spawns the workspace agent). Operator cards are
  # only create_project (no delete/navigation), so this stays simple.
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

  # Dive into a job's agent chat — re-anchor your read-position (delta → 0, so a
  # read done job retires), then navigate into that workspace's own stream.
  def handle_event("open_job", %{"ws" => ws, "project" => pid, "agent" => aid}, socket) do
    Loopyard.Operator.Jobs.mark_read(ws)
    {:noreply, push_navigate(socket, to: ~p"/projects/#{pid}/workspaces/#{ws}/agents/#{aid}")}
  end

  def handle_event(_evt, _params, socket), do: {:noreply, socket}

  # --- Message + streaming events: delegate to the SAME handlers the workspace
  # chat uses, so the operator gets incremental append + live streaming. ---

  @impl true
  def handle_info(%Events.ChatAgentMessage.Message{} = e, socket),
    do: AgentEvents.handle_message(e, socket)

  # Card status resolutions (approval → :renamed / :deleted / :approved / progress)
  # ride MessageUpdated. Without this the operator's cards freeze at their
  # optimistic status and never show the outcome (the "stuck Creating…" bug).
  def handle_info(%Events.ChatAgentMessage.MessageUpdated{} = e, socket),
    do: AgentEvents.on_message_updated(e, socket)

  def handle_info(%Events.ChatAgentMessage.TextDelta{} = e, socket),
    do: AgentEvents.handle_text_delta(e, socket)

  # Ambient play/pause/volume command from the operator's `music` tool → push to
  # this client's AmbientAudio engine (which applies it; the sound pill reflects).
  def handle_info(%Events.Aural.Command{action: action, value: value}, socket),
    do: {:noreply, push_event(socket, "aural_command", %{action: to_string(action), value: value})}

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
        %Events.ChatAgentMessage.StreamOutput{agent_id: id, data: data, title: title, msg_id: msg_id},
        socket
      )
      when id == socket.assigns.selected_id do
    stream_buffer = StreamBuffer.append(socket.assigns.stream_buffer, data, title: title, msg_id: msg_id)
    messages = StreamBuffer.upsert_message(stream_buffer, socket.assigns.messages)

    {:noreply,
     socket
     |> assign(:messages, messages)
     |> assign(:stream_buffer, stream_buffer)
     |> assign(:building, true)
     |> push_event("scroll_bottom", %{})}
  end

  def handle_info(%Events.ChatAgentMessage.StreamOutput{}, socket), do: {:noreply, socket}

  def handle_info(%Events.ChatAgent.StatusChanged{} = e, socket) do
    {:noreply, socket} = AgentEvents.handle_status_changed(e, socket)

    # The operator's OWN status drives the ambient bed — it swells while the
    # operator works, settles when idle. Best-effort; sound never blocks the page.
    if e.id == socket.assigns.agent_id, do: drive_sound(e.status)

    # Any agent's status change can move the board AND change what's blocking
    # (a question asked/answered rides a status change → :awaiting/back).
    {:noreply,
     socket
     |> assign(:tree, Loopyard.WorkspaceTree.global(socket.assigns.host))
     |> assign(:needs_you_count, Loopyard.Attention.count(socket.assigns.host))}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Operator activity → ambient loudness (Aural continuous level, 0..1).
  defp drive_sound(status) do
    level = if status in [:thinking, :backoff, :compacting], do: 0.7, else: 0.12
    Aural.Channel.set_activity("activity", level)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="operator-page"
      phx-hook="ScrollBottom"
      class="h-screen flex flex-col bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100 safe-area-x"
    >
      <Nav.bar height="h-14" gap="gap-3">
        <.breadcrumbs crumbs={[{"Loopyard", "/"}, {"Operator", nil}]} />
        <:actions>
          <%!-- "Needs you" → the town hall (/queue): the stack of blocking
               questions/secrets/approvals to go through, answerable inline. --%>
          <.link
            navigate={~p"/queue"}
            aria-label="Needs you — the town hall"
            class="focus-ring inline-flex items-center gap-1.5 rounded-full border border-zinc-200 dark:border-zinc-700 px-3 h-9 text-sm font-medium text-zinc-600 dark:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800 transition-colors"
          >
            Needs you
            <span
              :if={@needs_you_count > 0}
              class="inline-flex items-center justify-center min-w-[1.25rem] h-5 px-1 rounded-full bg-amber-500 text-white text-xs font-semibold"
            >
              {@needs_you_count}
            </span>
          </.link>
          <%!-- Stop lives in the chat's live-status (chat_panel), not up here. --%>
          <LoopyardWeb.Components.Common.sound_pill id="operator-sound" />
        </:actions>
      </Nav.bar>

      <div class="flex-1 min-h-0 flex">
        <%!-- Chat is PRIMARY — mostly you just talk to the operator. --%>
        <div class="flex-1 min-w-0 flex flex-col min-h-0">
          <.chat_panel
            messages={@messages}
            streaming_text={@streaming_text}
            streaming_thinking={@streaming_thinking}
            agent={@selected_agent}
            workspace_id={nil}
            host={@host}
            thinking_word={@thinking_word || "Thinking"}
            has_more_messages={@has_more_messages}
            window_tail?={@window_tail?}
            detail_level={:chat}
          />
        </div>
        <%!-- Desktop (lg+): the WORKER QUEUE (dispatched jobs + progress) as a
             persistent right rail. "Needs you" (the town hall) is the header
             link — a different surface (blocking items to answer). --%>
        <aside class="hidden lg:flex w-72 flex-none flex-col border-l border-zinc-200 dark:border-zinc-800 overflow-y-auto bg-zinc-50/60 dark:bg-zinc-900/40">
          <.attention_queue tree={@tree} />
        </aside>
      </div>
    </div>
    """
  end

  # The WORKER QUEUE: one card per job you've DISPATCHED (Operator.Queue). Starts
  # blank; each card shows project·workspace, the live state (working / done /
  # needs-you), and the "N new since you looked" delta. Clicking dives into that
  # agent's chat, which re-anchors your read-position (delta → 0, done cards
  # retire). Live: @tree rebuilds on every StatusChanged so this re-derives + re-ranks.
  attr :tree, :list, required: true

  defp attention_queue(assigns) do
    # Mark the jobs we've armed a "tell me when it's done" watch on, so the board
    # doubles as the live registry of "what am I waiting on".
    watched = Loopyard.Operator.Digest.watches() |> MapSet.new(& &1.ws_id)
    items = Loopyard.Operator.Queue.items(assigns.tree)
    items = Enum.map(items, &Map.put(&1, :watching?, MapSet.member?(watched, &1.id)))
    assigns = assign(assigns, :items, items)

    ~H"""
    <div class="p-3 space-y-1.5">
      <div class="text-xs font-semibold uppercase tracking-wide text-zinc-400 dark:text-zinc-500 px-1 pb-1">
        Worker queue
      </div>
      <p :if={@items == []} class="px-1 text-sm text-zinc-500 dark:text-zinc-400">
        Nothing dispatched yet — ask the operator to put a workspace to work.
      </p>
      <div
        :for={i <- @items}
        phx-click="open_job"
        phx-value-ws={i.id}
        phx-value-project={i.project_id}
        phx-value-agent={i.agent_id}
        class="rounded-lg px-2.5 py-2 border border-transparent hover:bg-zinc-100 dark:hover:bg-zinc-800/60 transition-colors cursor-pointer"
      >
        <div class="flex items-center gap-2">
          <span class={["flex-none w-1.5 h-1.5 rounded-full", state_dot(i.state)]} />
          <span class="flex-1 min-w-0 truncate text-sm font-medium text-zinc-700 dark:text-zinc-200">
            {i.project_name} · {i.workspace_name}
          </span>
          <span
            :if={i.watching?}
            title="Watching — you'll be told when this finishes"
            class="flex-none text-xs text-amber-600 dark:text-amber-400"
          >
            🔔
          </span>
          <span
            :if={i.delta > 0}
            class="flex-none text-xs font-semibold text-violet-600 dark:text-violet-400"
          >
            {i.delta} new
          </span>
        </div>
        <div class="mt-0.5 pl-3.5 text-xs truncate">
          <span class={state_text(i.state)}>{state_label(i.state)}</span><span
            :if={i.needs not in ["", state_label(i.state)]}
            class="text-zinc-500 dark:text-zinc-400"
          > · {i.needs}</span>
        </div>
      </div>
    </div>
    """
  end

  defp state_dot(:needs_you), do: "bg-amber-500"
  defp state_dot(:done), do: "bg-emerald-500"
  defp state_dot(:chugging), do: "bg-violet-500 animate-pulse"
  defp state_dot(_), do: "bg-zinc-400 dark:bg-zinc-500"

  defp state_text(:needs_you), do: "text-amber-600 dark:text-amber-400 font-medium"
  defp state_text(:done), do: "text-emerald-600 dark:text-emerald-400"
  defp state_text(:chugging), do: "text-violet-600 dark:text-violet-400"
  defp state_text(_), do: "text-zinc-500 dark:text-zinc-400"

  defp state_label(:needs_you), do: "needs you"
  defp state_label(:done), do: "done"
  defp state_label(:chugging), do: "working"
  defp state_label(_), do: ""
end
