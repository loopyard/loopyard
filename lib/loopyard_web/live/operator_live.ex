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
      |> load_agent()

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

    # Optimistic flip so the buttons don't sit unclicked while the project builds.
    if decision == :approve and card do
      ChatAgent.update_message(agent_id, card.id, &Map.put(&1, :status, :creating))
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

  def handle_event(_evt, _params, socket), do: {:noreply, socket}

  # --- Message + streaming events: delegate to the SAME handlers the workspace
  # chat uses, so the operator gets incremental append + live streaming. ---

  @impl true
  def handle_info(%Events.ChatAgentMessage.Message{} = e, socket),
    do: AgentEvents.handle_message(e, socket)

  def handle_info(%Events.ChatAgentMessage.TextDelta{} = e, socket),
    do: AgentEvents.handle_text_delta(e, socket)

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

  def handle_info(%Events.ChatAgent.StatusChanged{} = e, socket),
    do: AgentEvents.handle_status_changed(e, socket)

  def handle_info(_msg, socket), do: {:noreply, socket}

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
          <button
            :if={@selected_agent.status == :thinking}
            type="button"
            phx-click="interrupt_agent"
            phx-value-id={@agent_id}
            class="inline-flex items-center gap-1.5 rounded-md px-2.5 py-1.5 text-sm font-medium bg-red-500/10 text-red-600 dark:text-red-400 hover:bg-red-500/20 transition-colors"
          >
            <span class="w-2 h-2 rounded-sm bg-red-500"></span> Stop
          </button>
          <LoopyardWeb.Components.Common.sound_control id="sound-operator" />
        </:actions>
      </Nav.bar>

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
        detail_level={:trace}
      />
    </div>
    """
  end
end
