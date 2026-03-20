defmodule BoomLooperWeb.MessageLive do
  @moduledoc """
  Live view for a single message. Static messages show content.
  Streaming messages (build output) subscribe and update in real-time.
  Multiplayer — all viewers see the same content.
  """
  use BoomLooperWeb, :live_view

  @impl true
  def mount(%{"id" => agent_id, "index" => index_str} = params, _session, socket) do
    index = String.to_integer(index_str)
    token = Map.get(params, "token", "")

    # Verify signed token
    expected = "#{agent_id}:#{index_str}"
    case Phoenix.Token.verify(BoomLooperWeb.Endpoint, "msg", token, max_age: 3600) do
      {:ok, ^expected} ->
        state = BoomLooper.ChatAgent.get_state(agent_id)
        msg = if state, do: Enum.at(state[:messages] || [], index)

        if msg do
          # Subscribe to agent updates for live streaming
          if connected?(socket) do
            BoomLooper.ChatAgent.subscribe(agent_id)
          end

          raw_url = BoomLooperWeb.OutputController.signed_url(
            params["project_id"] || params["workspace_id"] || "x",
            agent_id, index) <> "&format=raw"

          {:ok,
           socket
           |> assign(:agent_id, agent_id)
           |> assign(:index, index)
           |> assign(:msg, msg)
           |> assign(:raw_url, raw_url)
           |> assign(:streaming, msg.role == :build)}
        else
          {:ok, socket |> assign(:msg, nil) |> assign(:raw_url, nil) |> assign(:streaming, false)}
        end

      _ ->
        {:ok, socket |> assign(:msg, nil) |> assign(:raw_url, nil) |> assign(:streaming, false)}
    end
  end

  # Update when build output changes
  @impl true
  def handle_info({:build_output, id, _data}, socket) when id == socket.assigns.agent_id do
    state = BoomLooper.ChatAgent.get_state(socket.assigns.agent_id)
    msg = if state, do: Enum.at(state[:messages] || [], socket.assigns.index)

    if msg do
      {:noreply, assign(socket, :msg, msg)}
    else
      {:noreply, socket}
    end
  end

  # Build complete — stop streaming
  @impl true
  def handle_info({:chat_message, id, %{role: role}}, socket)
      when id == socket.assigns.agent_id and role in [:system, :error] do
    if socket.assigns.streaming do
      # Refresh the message — it may have transitioned to :build_done
      state = BoomLooper.ChatAgent.get_state(socket.assigns.agent_id)
      msg = if state, do: Enum.at(state[:messages] || [], socket.assigns.index)
      if msg do
        {:noreply, socket |> assign(:msg, msg) |> assign(:streaming, msg.role == :build)}
      else
        {:noreply, assign(socket, :streaming, false)}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100">
      <header class="h-12 border-b border-zinc-200 dark:border-zinc-700/80 flex items-center justify-between px-4">
        <div class="flex items-center gap-2">
          <span class="text-sm font-medium text-zinc-500 dark:text-zinc-400">
            {message_type(@msg)}
          </span>
          <span :if={@streaming} class="flex items-center gap-1.5 text-xs text-amber-500">
            <div class="w-1.5 h-1.5 rounded-full bg-amber-400 animate-pulse"></div>
            live
          </span>
        </div>
        <a :if={@raw_url} href={@raw_url} target="_blank"
          class="text-xs text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-300 transition-colors">
          raw text
        </a>
      </header>

      <div :if={@msg} class="p-4">
        <pre :if={@msg.role in [:build, :build_done, :build_failed, :tool_result]}
          class="text-sm font-mono whitespace-pre-wrap bg-zinc-100 dark:bg-zinc-950 text-zinc-800 dark:text-green-400 rounded-lg p-4 overflow-auto"
        >{@msg.content}</pre>

        <div :if={@msg.role == :assistant}
          id="msg-content"
          phx-hook="Markdown"
          data-source={@msg.content}
          class="prose dark:prose-invert max-w-none">
          <div class="markdown-body"></div>
        </div>

        <div :if={@msg.role == :user}
          class="text-sm whitespace-pre-wrap">
          {@msg.content}
        </div>

        <div :if={@msg.role in [:system, :error]}
          class={"text-sm #{if @msg.role == :error, do: "text-red-600 dark:text-red-400", else: "text-zinc-500 dark:text-zinc-400 italic"}"}>
          {@msg.content}
        </div>
      </div>

      <div :if={!@msg} class="flex items-center justify-center h-64">
        <p class="text-sm text-zinc-400">Message not found or link expired</p>
      </div>
    </div>
    """
  end

  defp message_type(nil), do: "message"
  defp message_type(%{role: :assistant}), do: "assistant"
  defp message_type(%{role: :user}), do: "user"
  defp message_type(%{role: :build}), do: "build output"
  defp message_type(%{role: :build_done}), do: "build output"
  defp message_type(%{role: :build_failed}), do: "build output (failed)"
  defp message_type(%{role: :tool_result}), do: "tool output"
  defp message_type(%{role: :tool}), do: "tool call"
  defp message_type(%{role: :system}), do: "system"
  defp message_type(%{role: :error}), do: "error"
  defp message_type(_), do: "message"
end
