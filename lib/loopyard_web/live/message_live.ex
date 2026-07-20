defmodule LoopyardWeb.MessageLive do
  @moduledoc """
  Live view for a single message. Static messages show content.
  Streaming messages (build output, exec_stream) subscribe and update in real-time.
  Multiplayer — all viewers see the same content.
  """
  use LoopyardWeb, :live_view
  import LoopyardWeb.Components.LogViewer

  alias Loopyard.Events
  alias LoopyardWeb.Components.Nav

  @behaviour Loopyard.Events.ChatAgentMessage.Subscriber

  @impl true
  def mount(%{"agent_id" => agent_id, "msg_id" => msg_id}, _session, socket) do
    msg = Loopyard.ChatAgent.get_message(agent_id, msg_id)

    if msg do
      if connected?(socket) do
        Loopyard.ChatAgent.subscribe(agent_id)
      end

      raw_url = LoopyardWeb.OutputController.raw_url(agent_id, msg_id)
      streaming = msg.role in [:build, :stream]

      {:ok,
       socket
       |> assign(:agent_id, agent_id)
       |> assign(:msg_id, msg_id)
       |> assign(:msg, msg)
       |> assign(:raw_url, raw_url)
       |> assign(:streaming, streaming)
       |> assign(:streaming_text, "")
       # Local accumulator for streaming
       |> assign(:stream_content, msg.content || "")}
    else
      {:ok,
       socket
       |> assign(:msg, nil)
       |> assign(:raw_url, nil)
       |> assign(:streaming, false)
       |> assign(:agent_id, agent_id)
       |> assign(:msg_id, msg_id)
       |> assign(:streaming_text, "")
       |> assign(:stream_content, "")}
    end
  end

  # --- PubSub dispatch ---

  @impl true
  def handle_info(%Events.ChatAgentMessage.Message{} = e, socket), do: on_message(e, socket)

  def handle_info(%Events.ChatAgentMessage.MessageUpdated{} = e, socket),
    do: on_message_updated(e, socket)

  def handle_info(%Events.ChatAgentMessage.TextDelta{} = e, socket), do: on_text_delta(e, socket)

  def handle_info(%Events.ChatAgentMessage.StreamOutput{} = e, socket),
    do: on_stream_output(e, socket)

  # Non-PubSub build-output events (sent as {:build_output, …} intra-
  # process — not a publisher-module topic).
  def handle_info({:build_output, id, data}, socket) when id == socket.assigns.agent_id do
    # Accumulate build output locally
    new_content = socket.assigns.stream_content <> data
    {:noreply, socket |> assign(:stream_content, new_content) |> assign(:streaming, true)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  # --- Subscriber callbacks ---

  # Streaming text deltas for assistant messages — accumulate for real-time display.
  @impl Events.ChatAgentMessage.Subscriber
  def on_text_delta(%Events.ChatAgentMessage.TextDelta{agent_id: id, text: text}, socket)
      when id == socket.assigns.agent_id do
    {:noreply, assign(socket, :streaming_text, socket.assigns.streaming_text <> text)}
  end

  def on_text_delta(_e, socket), do: {:noreply, socket}

  # Stream output for build/exec_stream — accumulate locally for instant updates.
  @impl Events.ChatAgentMessage.Subscriber
  def on_stream_output(
        %Events.ChatAgentMessage.StreamOutput{agent_id: id, msg_id: msg_id, data: data},
        socket
      )
      when id == socket.assigns.agent_id and msg_id == socket.assigns.msg_id do
    new_content = socket.assigns.stream_content <> data
    {:noreply, socket |> assign(:stream_content, new_content) |> assign(:streaming, true)}
  end

  def on_stream_output(_e, socket), do: {:noreply, socket}

  # Completed chat messages — refresh if this is our message being updated.
  @impl Events.ChatAgentMessage.Subscriber
  def on_message(%Events.ChatAgentMessage.Message{agent_id: id, msg: %{id: msg_id} = msg}, socket)
      when id == socket.assigns.agent_id and msg_id == socket.assigns.msg_id do
    # Clear streaming text when full message arrives
    socket = if msg.role == :assistant, do: assign(socket, :streaming_text, ""), else: socket
    {:noreply, socket |> assign(:msg, msg) |> assign(:stream_content, msg.content || "")}
  end

  # Build/stream complete (system message arrives) — refresh to pull the
  # terminal role (:build_done / :build_failed) from ETS.
  def on_message(%Events.ChatAgentMessage.Message{agent_id: id, msg: %{role: role}}, socket)
      when id == socket.assigns.agent_id and role in [:system, :error] do
    if socket.assigns.streaming do
      refresh_message(socket)
    else
      {:noreply, socket}
    end
  end

  def on_message(_e, socket), do: {:noreply, socket}

  # In-place change to the message this view shows (question answered, approval
  # resolved) — swap it in directly.
  @impl Events.ChatAgentMessage.Subscriber
  def on_message_updated(
        %Events.ChatAgentMessage.MessageUpdated{agent_id: id, msg: %{id: msg_id} = msg},
        socket
      )
      when id == socket.assigns.agent_id and msg_id == socket.assigns.msg_id do
    {:noreply, assign(socket, :msg, msg)}
  end

  def on_message_updated(_e, socket), do: {:noreply, socket}

  defp refresh_message(socket) do
    msg = Loopyard.ChatAgent.get_message(socket.assigns.agent_id, socket.assigns.msg_id)

    if msg do
      {:noreply,
       socket
       |> assign(:msg, msg)
       |> assign(:streaming, msg.role in [:build, :stream])
       |> assign(:stream_content, msg.content || "")}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100 safe-area-x">
      <Nav.bar height="h-12" pad="px-4">
        <span :if={@msg} class="text-sm font-medium text-zinc-500 dark:text-zinc-400">
          {@msg[:title] || message_type(@msg)}
        </span>
        <span :if={@streaming} class="flex items-center gap-1.5 text-xs text-amber-500">
          <div class="w-1.5 h-1.5 rounded-full bg-amber-400 animate-pulse"></div>
          live
        </span>
        <:actions>
          <a
            :if={@raw_url}
            href={@raw_url}
            class="text-xs text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-300 transition-colors"
          >
            raw text
          </a>
        </:actions>
      </Nav.bar>

      <div :if={@msg} class="p-4">
        <.log_panel
          :if={@msg.role in [:build, :build_done, :build_failed, :stream, :tool_result]}
          id="msg-output"
          content={@stream_content}
          class="text-sm rounded-lg p-4 max-h-[calc(100vh-6rem)]"
        />

        <div :if={@msg.role == :assistant} id="msg-content" class="prose dark:prose-invert max-w-none">
          <div class="markdown-body">
            {Loopyard.Markdown.to_html(
              if @streaming_text != "", do: @streaming_text, else: @msg.content
            )}
          </div>
        </div>

        <%!-- Show streaming indicator when accumulating text --%>
        <div
          :if={@streaming_text != "" && @msg.role == :assistant}
          class="mt-2 flex items-center gap-1.5 text-xs text-amber-500"
        >
          <div class="w-1.5 h-1.5 rounded-full bg-amber-400 animate-pulse"></div>
          streaming...
        </div>

        <div
          :if={@msg.role == :user}
          class="text-sm whitespace-pre-wrap"
        >
          {@msg.content}
        </div>

        <div
          :if={@msg.role in [:system, :error]}
          class={"text-sm #{if @msg.role == :error, do: "text-red-600 dark:text-red-400", else: "text-zinc-500 dark:text-zinc-400 italic"}"}
        >
          {@msg.content}
        </div>
      </div>

      <div :if={!@msg} class="flex items-center justify-center h-64">
        <p class="text-sm text-zinc-400">Message not found or link expired</p>
      </div>
    </div>
    """
  end

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
