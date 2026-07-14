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
  def handle_event("send_message", %{"message" => text}, socket) do
    ChatAgent.send_message(socket.assigns.agent_id, text)
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
      <Nav.bar pad="px-4">
        <span class="w-2 h-2 rounded-full flex-none bg-sky-500"></span>
        <h1 class="text-lg font-semibold">Operator</h1>
        <span class="text-sm text-zinc-400 dark:text-zinc-500">· {@agent.status}</span>
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
          <Nav.back_button navigate="/" label="Home" />
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
