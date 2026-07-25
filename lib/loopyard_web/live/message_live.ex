defmodule LoopyardWeb.MessageLive do
  @moduledoc """
  Permalink view for a TURN — a user prompt plus the whole run of the agent's
  response below it, up to (not including) the next user turn. Renders like the
  chat, and STREAMS live: subscribe to the agent, append new messages of this
  turn as they land, accumulate in-flight assistant text, and stop when the next
  user turn begins. Any single message id in a turn resolves to the same turn, so
  every item in the chat is reachable by linking its turn. Multiplayer — all
  viewers see the same live turn.
  """
  use LoopyardWeb, :live_view

  alias Loopyard.Events
  alias LoopyardWeb.Components.Nav

  @behaviour Loopyard.Events.ChatAgentMessage.Subscriber

  @impl true
  def mount(%{"agent_id" => agent_id, "msg_id" => msg_id}, _session, socket) do
    {mode, turn, anchor} = LoopyardWeb.TurnSlice.resolve(agent_id, msg_id)

    # Only a live TURN streams new content below it. A single-message permalink
    # is a static artifact — subscribe just to catch an in-place update of that
    # one message; a lone message never grows into a turn.
    if connected?(socket) and anchor, do: Loopyard.ChatAgent.subscribe(agent_id)

    {:ok,
     socket
     |> assign(:agent_id, agent_id)
     |> assign(:msg_id, msg_id)
     |> assign(:mode, mode)
     |> assign(:anchor, anchor)
     |> assign(:turn, turn)
     # id of the user message that STARTED this turn — used to detect when the
     # NEXT user turn begins (which closes this one).
     |> assign(:turn_start_id, anchor && anchor[:id])
     # Single messages never stream below; a turn is closed once a later user
     # prompt already exists (historical).
     |> assign(:closed?, mode == :single or turn_closed?(agent_id, anchor))
     |> assign(:streaming_text, "")
     |> assign(:raw_url, LoopyardWeb.OutputController.raw_url(agent_id, msg_id))}
  end

  # Is there already a NEXT user turn after this one? Then it's historical (no
  # live streaming to expect).
  defp turn_closed?(_agent_id, nil), do: true

  defp turn_closed?(agent_id, anchor) do
    msgs = (Loopyard.ChatAgent.get_state(agent_id) || %{})[:messages] || []
    start = Enum.find_index(msgs, &(&1[:id] == anchor[:id])) || 0

    msgs
    |> Enum.drop(start + 1)
    |> Enum.any?(&(&1[:role] == :user))
  end

  # --- streaming: append new messages of THIS turn, accumulate live text ---

  @impl true
  def handle_info(%Events.ChatAgentMessage.Message{} = e, socket), do: on_message(e, socket)

  def handle_info(%Events.ChatAgentMessage.MessageUpdated{} = e, socket),
    do: on_message_updated(e, socket)

  def handle_info(%Events.ChatAgentMessage.TextDelta{} = e, socket), do: on_text_delta(e, socket)

  def handle_info(_e, socket), do: {:noreply, socket}

  @impl Events.ChatAgentMessage.Subscriber
  def on_text_delta(%Events.ChatAgentMessage.TextDelta{agent_id: id, text: text}, socket)
      when id == socket.assigns.agent_id do
    if socket.assigns.closed?,
      do: {:noreply, socket},
      else: {:noreply, assign(socket, :streaming_text, socket.assigns.streaming_text <> text)}
  end

  def on_text_delta(_e, socket), do: {:noreply, socket}

  @impl Events.ChatAgentMessage.Subscriber
  def on_message(%Events.ChatAgentMessage.Message{agent_id: id, msg: msg}, socket)
      when id == socket.assigns.agent_id do
    cond do
      socket.assigns.closed? ->
        {:noreply, socket}

      # A NEW user message (not our turn's start) begins the NEXT turn — close this one.
      msg[:role] == :user and msg[:id] != socket.assigns.turn_start_id ->
        {:noreply, socket |> assign(:closed?, true) |> assign(:streaming_text, "")}

      # Already have it (dedupe) — ignore.
      Enum.any?(socket.assigns.turn, &(&1[:id] == msg[:id])) ->
        {:noreply, socket}

      # A continuation of THIS turn — append, and clear the in-flight text an
      # assistant message just finalized.
      true ->
        st = if msg[:role] == :assistant, do: "", else: socket.assigns.streaming_text
        {:noreply, socket |> assign(:turn, socket.assigns.turn ++ [msg]) |> assign(:streaming_text, st)}
    end
  end

  def on_message(_e, socket), do: {:noreply, socket}

  @impl Events.ChatAgentMessage.Subscriber
  def on_message_updated(%Events.ChatAgentMessage.MessageUpdated{agent_id: id, msg: msg}, socket)
      when id == socket.assigns.agent_id do
    turn = Enum.map(socket.assigns.turn, fn m -> if m[:id] == msg[:id], do: msg, else: m end)
    {:noreply, assign(socket, :turn, turn)}
  end

  def on_message_updated(_e, socket), do: {:noreply, socket}

  def on_stream_output(_e, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100 safe-area-x">
      <Nav.bar height="h-12" pad="px-4">
        <.link
          navigate={"/messages/#{@agent_id}/#{@msg_id}"}
          class="text-sm font-medium text-zinc-600 dark:text-zinc-300"
        >
          {if @mode == :single, do: "Message", else: "Turn"}
        </.link>
        <span
          :if={!@closed? && @streaming_text != ""}
          class="flex items-center gap-1.5 text-xs text-violet-500"
        >
          <span class="w-1.5 h-1.5 rounded-full bg-violet-400 animate-pulse"></span> live
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

      <%!-- The turn, constrained to a reading measure so it reads like a
           document. A read-only per-role view (interactive cards link into the
           live chat), streaming the whole exchange until the next turn. --%>
      <div :if={@turn != []} class="mx-auto w-full max-w-3xl px-4 md:px-6 py-6 space-y-4">
        <.turn_msg :for={m <- @turn} msg={m} agent_id={@agent_id} />

        <%!-- In-flight assistant text (before it commits as a message). --%>
        <div :if={!@closed? && @streaming_text != ""}>
          <div class="markdown-body">
            {Phoenix.HTML.raw(Loopyard.Markdown.to_html(@streaming_text))}
          </div>
          <div class="mt-2 flex items-center gap-1.5 text-xs text-violet-500">
            <span class="w-1.5 h-1.5 rounded-full bg-violet-400 animate-pulse"></span> streaming…
          </div>
        </div>
      </div>

      <div :if={@turn == []} class="flex items-center justify-center h-64">
        <p class="text-sm text-zinc-400">Turn not found or link expired</p>
      </div>
    </div>
    """
  end

  # --- read-only per-role rendering of a turn's messages ---

  def turn_msg(%{msg: %{role: :user, content: c}} = assigns) when is_binary(c) do
    ~H"""
    <div class="rounded-xl bg-violet-100 dark:bg-[#2b2348] px-4 py-3 text-[15px] leading-relaxed whitespace-pre-wrap text-zinc-900 dark:text-zinc-50">
      {@msg.content}
    </div>
    """
  end

  def turn_msg(%{msg: %{role: :assistant, content: c}} = assigns) when is_binary(c) and c != "" do
    ~H"""
    <div class="markdown-body">
      {Phoenix.HTML.raw(Loopyard.Markdown.to_html(@msg.content))}
    </div>
    """
  end

  def turn_msg(%{msg: %{role: :tool}} = assigns) do
    ~H"""
    <div class="font-mono text-xs text-zinc-500 dark:text-zinc-400">⚙ {@msg[:tool] || "tool"}</div>
    """
  end

  def turn_msg(%{msg: %{role: role, content: c}} = assigns)
      when role in [:tool_result, :build, :build_done, :build_failed] and is_binary(c) do
    ~H"""
    <pre class="text-xs font-mono whitespace-pre-wrap overflow-x-auto rounded-lg bg-zinc-100 dark:bg-zinc-950 text-zinc-700 dark:text-zinc-300 p-3 max-h-64 overflow-y-auto">{@msg.content}</pre>
    """
  end

  def turn_msg(%{msg: %{role: :system, content: c}} = assigns) when is_binary(c) do
    ~H"""
    <div class="py-1 text-center text-sm italic text-zinc-400/70 dark:text-zinc-600">{@msg.content}</div>
    """
  end

  def turn_msg(%{msg: %{role: :error, content: c}} = assigns) when is_binary(c) do
    ~H"""
    <div class="text-sm text-red-600 dark:text-red-400 whitespace-pre-wrap">{@msg.content}</div>
    """
  end

  def turn_msg(%{msg: %{role: :embed}} = assigns) do
    ~H"""
    <.link
      navigate={"/projects/#{@msg[:project_id]}/workspaces/#{@msg[:workspace_id]}/agents/#{@msg[:agent_id]}"}
      class="inline-flex items-center gap-2 rounded-lg border border-zinc-200 dark:border-zinc-700 px-3 py-2 text-sm text-violet-600 dark:text-violet-400 hover:bg-zinc-50 dark:hover:bg-zinc-800/50"
    >
      ▸ {@msg[:label] || "workspace"} — open in chat →
    </.link>
    """
  end

  def turn_msg(%{msg: %{role: role}} = assigns)
      when role in [:question, :approval, :secret_request] do
    ~H"""
    <div class="rounded-lg border border-amber-200 dark:border-amber-900/50 bg-amber-50 dark:bg-amber-950/20 px-3 py-2 text-sm text-amber-700 dark:text-amber-400">
      Needs your input — answer it in the live chat.
    </div>
    """
  end

  def turn_msg(assigns), do: ~H""
end
