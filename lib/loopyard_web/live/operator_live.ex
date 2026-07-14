defmodule LoopyardWeb.OperatorLive do
  @moduledoc """
  `/operator` — the operator agent's own chat, standalone (no workspace chrome).
  The operator is a host-side `Harness.Claude` agent with no workspace/project, so
  it can't render through the workspace view — it gets its own focused screen:
  a header + the shared `chat_panel`. Created on first visit
  (`Loopyard.Operator.ensure_agent/0`).
  """
  use LoopyardWeb, :live_view

  alias Loopyard.{ChatAgent, Operator}
  alias LoopyardWeb.Components.Nav
  import LoopyardWeb.Components.Breadcrumbs, only: [breadcrumbs: 1]
  import LoopyardWeb.Live.WorkspaceLive.Components.Chat, only: [chat_panel: 1]

  @impl true
  def mount(_params, _session, socket) do
    {:ok, %{agent_id: agent_id}} = Operator.ensure_agent()

    if connected?(socket) do
      Loopyard.Events.ChatAgentMessage.subscribe(agent_id)
      Loopyard.Events.ChatAgent.subscribe()
    end

    host =
      case socket.host_uri do
        %URI{host: h} when is_binary(h) and h != "" -> h
        _ -> "localhost"
      end

    {:ok, socket |> assign(:agent_id, agent_id) |> assign(:host, host) |> load()}
  end

  defp load(socket) do
    case ChatAgent.get_state(socket.assigns.agent_id) do
      %{} = st -> assign(socket, agent: st, messages: st.messages)
      _ -> assign(socket, agent: %{id: socket.assigns.agent_id, status: :idle}, messages: [])
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
    text = Enum.at(socket.assigns.agent[:pending_messages] || [], index)
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

    {:noreply, load(socket)}
  end

  def handle_event(_evt, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info(%Loopyard.Events.ChatAgentMessage.Message{agent_id: id}, socket)
      when id == socket.assigns.agent_id,
      do: {:noreply, load(socket)}

  def handle_info(%Loopyard.Events.ChatAgent.StatusChanged{id: id}, socket)
      when id == socket.assigns.agent_id,
      do: {:noreply, load(socket)}

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-screen flex flex-col bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100 safe-area-x">
      <Nav.bar height="h-14" gap="gap-3">
        <.breadcrumbs crumbs={[{"Loopyard", "/"}, {"Operator", nil}]} />
        <:actions>
          <button
            :if={@agent.status == :thinking}
            type="button"
            phx-click="interrupt_agent"
            phx-value-id={@agent_id}
            class="inline-flex items-center gap-1.5 rounded-md px-2.5 py-1.5 text-sm font-medium bg-red-500/10 text-red-600 dark:text-red-400 hover:bg-red-500/20 transition-colors"
          >
            <span class="w-2 h-2 rounded-sm bg-red-500"></span> Stop
          </button>
        </:actions>
      </Nav.bar>

      <.chat_panel
        messages={@messages}
        streaming_text=""
        streaming_thinking=""
        agent={@agent}
        workspace_id={nil}
        host={@host}
        thinking_word="Thinking"
        has_more_messages={false}
        window_tail?={true}
        detail_level={:trace}
      />
    </div>
    """
  end
end
