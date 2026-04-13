defmodule BoomLooperWeb.Live.ChatLive.Messages do
  @moduledoc """
  Chat message rendering — every `chat_msg/1` clause and its supporting
  helpers, extracted from `BoomLooperWeb.ChatLive` to keep that file
  navigable.

  Each clause in `chat_msg/1` handles one message role (user, assistant,
  tool, tool_result, error, build, build_done, build_failed, system).
  Plus `streaming_bubble/1` for the in-progress assistant text.

  These are public function components — `BoomLooperWeb.ChatLive`
  imports them and renders `<.chat_msg ... />` inline.

  This file is intentionally template-only. It does NOT touch sockets,
  GenServers, or PubSub — only assigns. That makes it safe to test in
  isolation and trivial to reuse outside the chat panel if we ever
  want to (e.g., a message permalink page).
  """
  use Phoenix.Component

  import BoomLooperWeb.Components.LogViewer, only: [log_inline: 1]

  alias BoomLooperWeb.Components.Ansi

  alias BoomLooperWeb.Components.ToolSummary

  attr :msg, :map, required: true
  attr :idx, :integer, required: true
  attr :agent_id, :string, required: true
  attr :workspace_id, :string, default: nil
  attr :host, :string, default: "localhost"

  def chat_msg(%{msg: %{role: :user}} = assigns) do
    assigns = assign(assigns, :url, msg_url(assigns))

    ~H"""
    <div class="flex justify-end mt-3 mb-1 group/msg">
      <div class="relative max-w-[85%] rounded-2xl rounded-tr-sm bg-violet-600 text-white px-4 py-2.5" id={"msg-user-#{hash_content(@msg.content)}"} phx-hook="Markdown" data-source={@msg.content}>
        <a :if={@url} href={@url} target="_blank" rel="noopener"
          class="absolute top-2 left-2 p-1 rounded-md text-violet-300 hover:text-white opacity-0 group-hover/msg:opacity-100 transition-opacity"
          title="Open">
          <svg class="w-3 h-3" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor">
            <path d="M6.22 8.72a.75.75 0 0 0 1.06 1.06l5.22-5.22v1.69a.75.75 0 0 0 1.5 0v-3.5a.75.75 0 0 0-.75-.75h-3.5a.75.75 0 0 0 0 1.5h1.69L6.22 8.72Z" />
            <path d="M3.5 6.75c0-.69.56-1.25 1.25-1.25H7A.75.75 0 0 0 7 4H4.75A2.75 2.75 0 0 0 2 6.75v4.5A2.75 2.75 0 0 0 4.75 14h4.5A2.75 2.75 0 0 0 12 11.25V9a.75.75 0 0 0-1.5 0v2.25c0 .69-.56 1.25-1.25 1.25h-4.5c-.69 0-1.25-.56-1.25-1.25v-4.5Z" />
          </svg>
        </a>
        <div class="markdown-body markdown-body-user text-sm"></div>
      </div>
    </div>
    """
  end

  def chat_msg(%{msg: %{role: :assistant, content: content}} = assigns)
      when content in [nil, ""] do
    ~H"""
    <div></div>
    """
  end

  def chat_msg(%{msg: %{role: :assistant}} = assigns) do
    assigns = assign(assigns, :url, msg_url(assigns))
    assigns = assign(assigns, :rendered_content, rewrite_localhost_urls(assigns.msg.content, assigns[:host]))

    ~H"""
    <div class="flex gap-3 mt-3 mb-1 group/msg">
      <div class="flex-none w-7 h-7 rounded-full bg-violet-100 dark:bg-violet-900/40 flex items-center justify-center mt-0.5">
        <span class="text-xs font-bold text-violet-600 dark:text-violet-400">C</span>
      </div>
      <div class="relative max-w-[85%] rounded-2xl rounded-tl-sm bg-zinc-100 dark:bg-zinc-800 px-4 py-2.5" id={"msg-#{hash_content(@msg.content)}"} phx-hook="Markdown" data-source={@rendered_content}>
        <a :if={@url} href={@url} target="_blank" rel="noopener"
          class="absolute top-2 right-2 p-1 rounded-md text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-300 hover:bg-zinc-200 dark:hover:bg-zinc-700 opacity-0 group-hover/msg:opacity-100 transition-opacity"
          title="Open">
          <svg class="w-3.5 h-3.5" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor">
            <path d="M6.22 8.72a.75.75 0 0 0 1.06 1.06l5.22-5.22v1.69a.75.75 0 0 0 1.5 0v-3.5a.75.75 0 0 0-.75-.75h-3.5a.75.75 0 0 0 0 1.5h1.69L6.22 8.72Z" />
            <path d="M3.5 6.75c0-.69.56-1.25 1.25-1.25H7A.75.75 0 0 0 7 4H4.75A2.75 2.75 0 0 0 2 6.75v4.5A2.75 2.75 0 0 0 4.75 14h4.5A2.75 2.75 0 0 0 12 11.25V9a.75.75 0 0 0-1.5 0v2.25c0 .69-.56 1.25-1.25 1.25h-4.5c-.69 0-1.25-.56-1.25-1.25v-4.5Z" />
          </svg>
        </a>
        <div class="markdown-body text-sm text-zinc-900 dark:text-zinc-100"></div>
      </div>
    </div>
    """
  end

  def chat_msg(%{msg: %{role: :tool}} = assigns) do
    assigns = assign(assigns, :summary, ToolSummary.summarize(assigns.msg.tool, assigns.msg.input))

    ~H"""
    <div class="flex items-center gap-2 py-1 pl-10">
      <div class="w-4 h-4 rounded bg-blue-100 dark:bg-blue-900/40 flex items-center justify-center flex-none">
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-2.5 h-2.5 text-blue-500 dark:text-blue-400">
          <path fill-rule="evenodd" d="M6.955 1.45A.5.5 0 0 1 7.452 1h1.096a.5.5 0 0 1 .497.45l.17 1.699c.484.12.94.312 1.356.562l1.321-.916a.5.5 0 0 1 .67.033l.774.775a.5.5 0 0 1 .034.67l-.916 1.32c.25.417.443.873.563 1.357l1.699.17a.5.5 0 0 1 .45.497v1.096a.5.5 0 0 1-.45.497l-1.699.17c-.12.484-.312.94-.562 1.356l.916 1.321a.5.5 0 0 1-.034.67l-.774.774a.5.5 0 0 1-.67.033l-1.32-.916c-.417.25-.874.443-1.357.563l-.17 1.699a.5.5 0 0 1-.497.45H7.452a.5.5 0 0 1-.497-.45l-.17-1.699a4.973 4.973 0 0 1-1.356-.562l-1.321.916a.5.5 0 0 1-.67-.033l-.774-.775a.5.5 0 0 1-.034-.67l.916-1.32a4.971 4.971 0 0 1-.562-1.357l-1.699-.17A.5.5 0 0 1 1 8.548V7.452a.5.5 0 0 1 .45-.497l1.699-.17c.12-.484.312-.94.562-1.356l-.916-1.321a.5.5 0 0 1 .034-.67l.774-.774a.5.5 0 0 1 .67-.033l1.32.916c.417-.25.874-.443 1.357-.563l.17-1.699ZM8 10.5a2.5 2.5 0 1 0 0-5 2.5 2.5 0 0 0 0 5Z" clip-rule="evenodd" />
        </svg>
      </div>
      <span class="text-sm text-blue-600 dark:text-blue-400">{@summary}</span>
    </div>
    """
  end

  def chat_msg(%{msg: %{role: :tool_result}} = assigns) do
    content = assigns.msg.content

    if is_binary(content) && String.contains?(content, "completed with no output") do
      ~H"<div></div>"
    else
      chat_msg_tool_result(assigns)
    end
  end

  def chat_msg(%{msg: %{role: :error}} = assigns) do
    ~H"""
    <div class="flex items-start gap-2 py-1 pl-10">
      <div class="w-4 h-4 rounded bg-red-100 dark:bg-red-900/30 flex items-center justify-center flex-none mt-0.5">
        <span class="text-[10px] font-bold text-red-500">!</span>
      </div>
      <span class="text-xs text-red-600 dark:text-red-400">{Ansi.to_html(@msg.content)}</span>
      <span class="text-[10px] text-zinc-300 dark:text-zinc-600 flex-none">{Calendar.strftime(@msg.timestamp, "%H:%M:%S")}</span>
    </div>
    """
  end

  def chat_msg(%{msg: %{role: :build}} = assigns) do
    assigns = assign(assigns, :link, msg_url(assigns))
    ~H"""
    <.log_inline content={@msg.content} status={:building} raw_url={@link} title={@msg[:title]} />
    """
  end

  def chat_msg(%{msg: %{role: :build_done}} = assigns) do
    assigns = assign(assigns, :link, msg_url(assigns))
    ~H"""
    <.log_inline content={@msg.content} status={:done} raw_url={@link} title={@msg[:title]} />
    """
  end

  def chat_msg(%{msg: %{role: :build_failed}} = assigns) do
    assigns = assign(assigns, :link, msg_url(assigns))
    ~H"""
    <.log_inline content={@msg.content} status={:failed} raw_url={@link} title={@msg[:title]} />
    """
  end

  def chat_msg(%{msg: %{role: :system}} = assigns) do
    ~H"""
    <div class="py-1 pl-10">
      <div
        class="text-xs text-zinc-400 dark:text-zinc-500 italic"
        id={"system-msg-#{@msg[:id] || hash_content(@msg.content)}"}
        phx-hook="Markdown"
        data-source={@msg.content}
      >
        <div class="markdown-body"></div>
      </div>
    </div>
    """
  end

  def chat_msg(assigns) do
    ~H"""
    <div></div>
    """
  end

  attr :text, :string, required: true

  def streaming_bubble(assigns) do
    ~H"""
    <div class="flex gap-3 mt-3">
      <div class="flex-none w-7 h-7 rounded-full bg-violet-100 dark:bg-violet-900/40 flex items-center justify-center mt-0.5">
        <span class="text-xs font-bold text-violet-600 dark:text-violet-400">C</span>
      </div>
      <div class="max-w-[85%] rounded-2xl rounded-tl-sm bg-zinc-100 dark:bg-zinc-800 px-4 py-2.5" id="streaming-msg" phx-hook="Markdown" data-source={@text}>
        <div class="markdown-body text-sm text-zinc-900 dark:text-zinc-100"></div>
        <span class="inline-block w-1.5 h-4 bg-violet-500 animate-pulse ml-0.5 align-middle"></span>
      </div>
    </div>
    """
  end

  # --- Internal helpers ---

  defp chat_msg_tool_result(assigns) do
    content = assigns.msg.content
    display = format_tool_result(content)
    lines = String.split(display, "\n")
    truncated = length(lines) > 40
    display = if truncated, do: Enum.take(lines, 40) |> Enum.join("\n"), else: display
    url = msg_url(assigns)
    assigns = assign(assigns, display: display, truncated: truncated, is_error: assigns.msg.is_error, line_count: length(lines), url: url)

    ~H"""
    <div class="pl-10 py-0.5">
      <pre class={"p-3 rounded-lg text-xs font-mono overflow-x-auto max-h-80 overflow-y-auto whitespace-pre-wrap
                   #{if @is_error, do: "bg-red-50 dark:bg-red-950/30 text-red-700 dark:text-red-300", else: "bg-zinc-100 dark:bg-zinc-950 text-zinc-800 dark:text-zinc-300"}"}>{Ansi.to_html(@display)}</pre>
      <div class="flex items-center gap-2 mt-1">
        <p :if={@truncated} class="text-[10px] text-zinc-400 dark:text-zinc-500">... truncated ({@line_count - 40} more lines)</p>
        <a :if={@url} href={@url} target="_blank" rel="noopener" class="text-[10px] text-zinc-400 hover:text-zinc-300 transition-colors">open</a>
      </div>
    </div>
    """
  end

  defp msg_url(assigns) do
    msg_id = assigns.msg[:id]
    if msg_id do
      BoomLooperWeb.OutputController.msg_url(assigns.agent_id, msg_id)
    end
  end

  defp hash_content(content) when is_binary(content) do
    :erlang.phash2(content, 0xFFFFFF) |> Integer.to_string(16)
  end

  defp format_tool_result(content) do
    case Jason.decode(content) do
      {:ok, parsed} when is_map(parsed) ->
        Jason.encode!(parsed, pretty: true)

      _ ->
        content
    end
  end

  # Rewrite http://localhost:<port> URLs in message content to use the
  # viewer's actual hostname. Tools emit localhost URLs (host-agnostic);
  # this function makes them work for each viewer (LAN IP, tunnel, etc.).
  # Only rewrites URLs with explicit ports (http://localhost:32794/...) —
  # plain localhost without a port is left alone (it's a BoomLooper-relative
  # path that the browser handles).
  defp rewrite_localhost_urls(content, nil), do: content
  defp rewrite_localhost_urls(content, "localhost"), do: content

  defp rewrite_localhost_urls(content, host) when is_binary(content) and is_binary(host) do
    String.replace(content, "http://localhost:", "http://#{host}:")
  end

  defp rewrite_localhost_urls(content, _host), do: content
end
