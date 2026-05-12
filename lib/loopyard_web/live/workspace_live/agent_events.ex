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
          booting_agent_name: summary.name,
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
        |> update(:messages_total, &(&1 + 1))
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

  def handle_text_delta(%{agent_id: id, text: text}, socket)
      when id == socket.assigns.selected_id do
    {:noreply,
     socket
     |> assign(:streaming_text, text)
     |> push_event("scroll_bottom", %{})}
  end

  def handle_text_delta(_event, socket), do: {:noreply, socket}
end
