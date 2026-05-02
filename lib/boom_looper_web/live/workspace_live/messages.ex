defmodule BoomLooperWeb.Live.WorkspaceLive.Messages do
  @moduledoc """
  Chat message rendering — every `chat_msg/1` clause and its supporting
  helpers, extracted from `BoomLooperWeb.WorkspaceLive` to keep that file
  navigable.

  Each clause in `chat_msg/1` handles one message role (user, assistant,
  tool, tool_result, error, build, build_done, build_failed, system).
  Plus `streaming_bubble/1` for the in-progress assistant text.

  These are public function components — `BoomLooperWeb.WorkspaceLive`
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
    assigns = assign(assigns, :raw, raw_url(assigns))

    ~H"""
    <div class="flex flex-col items-end mt-3 mb-1 group/msg">
      <div class="max-w-[85%] rounded-2xl rounded-tr-sm bg-violet-600 text-white px-4 py-2.5" id={"msg-user-#{hash_content(@msg.content)}"} phx-hook="Markdown" data-source={@msg.content}>
        <div class="markdown-body markdown-body-user text-base"></div>
      </div>
      <div class="flex items-center gap-1 mt-0.5 h-5 opacity-0 group-hover/msg:opacity-100 transition-opacity">
        <.copy_btn :if={@raw} raw_url={@raw} />
        <.open_btn :if={@url} url={@url} />
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
    assigns = assign(assigns, :raw, raw_url(assigns))
    assigns = assign(assigns, :rendered_content, rewrite_localhost_urls(assigns.msg.content, assigns[:host]))
    assigns = assign(assigns, :port_info, detect_port_info(assigns.msg.content, assigns[:workspace_id]))

    ~H"""
    <div class="mt-3 mb-1 group/msg">
      <div class="flex gap-3">
        <div class="flex-none w-7 h-7 rounded-full bg-violet-100 dark:bg-violet-900/40 flex items-center justify-center mt-0.5">
          <span class="text-xs font-bold text-violet-600 dark:text-violet-400">C</span>
        </div>
        <div class="max-w-[85%] rounded-2xl rounded-tl-sm bg-zinc-100 dark:bg-zinc-800 px-4 py-2.5" id={"msg-#{hash_content(@msg.content)}"} phx-hook="Markdown" data-source={@rendered_content}>
          <div class="markdown-body text-base text-zinc-900 dark:text-zinc-100"></div>
        </div>
      </div>
      <div :if={@port_info && !@port_info.exposed} class="ml-10 mt-1.5 flex items-center gap-2 py-1">
        <div class="w-1.5 h-1.5 rounded-full flex-none bg-amber-400"></div>
        <span class="text-xs text-zinc-500 dark:text-zinc-400">{@port_info.service} port closed</span>
        <button
          phx-click="open_port_from_chat"
          phx-value-service={@port_info.service}
          phx-value-container_port={@port_info.container_port}
          class="inline-flex items-center px-1.5 rounded text-[10px] font-medium text-zinc-500 dark:text-zinc-400 hover:bg-zinc-200 dark:hover:bg-zinc-700 transition-colors"
        >
          Open Port
        </button>
      </div>
      <div :if={@port_info && @port_info.exposed} class="ml-10 mt-1.5 flex items-center gap-2 py-1">
        <div class="w-1.5 h-1.5 rounded-full flex-none bg-emerald-500"></div>
        <span class="text-xs text-zinc-500 dark:text-zinc-400">{@port_info.service} :{@port_info.host_port} open</span>
      </div>
      <div class="flex items-center gap-1 ml-10 mt-0.5 h-5 opacity-0 group-hover/msg:opacity-100 transition-opacity">
        <.copy_btn :if={@raw} raw_url={@raw} />
        <.open_btn :if={@url} url={@url} />
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
      <span class="text-base text-blue-600 dark:text-blue-400">{@summary}</span>
    </div>
    """
  end

  def chat_msg(%{msg: %{role: :tool_result}} = assigns) do
    content = assigns.msg.content

    cond do
      is_binary(content) && String.contains?(content, "completed with no output") ->
        ~H"<div></div>"

      # exec output is already shown in the streaming build message above —
      # don't render it twice.
      streamed_exec_result?(assigns) ->
        ~H"<div></div>"

      # URL with closed port — show the link + an Open Port button
      is_binary(content) && String.contains?(content, "port is local-only") ->
        chat_msg_port_closed(assigns)

      true ->
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
        <div class="markdown-body text-base text-zinc-900 dark:text-zinc-100"></div>
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
    raw = raw_url(assigns)
    assigns = assign(assigns, display: display, truncated: truncated, is_error: assigns.msg.is_error, line_count: length(lines), url: url, raw: raw)

    ~H"""
    <div class="pl-10 py-0.5 group/result">
      <pre class={"p-3 rounded-lg text-xs font-mono overflow-x-auto max-h-80 overflow-y-auto whitespace-pre-wrap
                   #{if @is_error, do: "bg-red-50 dark:bg-red-950/30 text-red-700 dark:text-red-300", else: "bg-zinc-100 dark:bg-zinc-950 text-zinc-800 dark:text-zinc-300"}"}>{Ansi.to_html(@display)}</pre>
      <div class="flex items-center gap-2 mt-1 h-5">
        <p :if={@truncated} class="text-[10px] text-zinc-400 dark:text-zinc-500">... truncated ({@line_count - 40} more lines)</p>
        <.copy_btn :if={@raw} raw_url={@raw} class="opacity-0 group-hover/result:opacity-100 transition-opacity" />
        <.open_btn :if={@url} url={@url} class="opacity-0 group-hover/result:opacity-100 transition-opacity" />
      </div>
    </div>
    """
  end

  # Check if this tool_result has a streamed build message above it —
  # the output was already shown live, so rendering it again is redundant.
  # Message order is: :tool (exec) → :build_done (streamed output) → :tool_result
  defp streamed_exec_result?(assigns) do
    idx = assigns[:idx]
    messages = assigns[:messages]

    if idx && messages && idx > 0 do
      # Walk backwards from this tool_result to find the matching :tool call,
      # skipping any build/build_done/build_failed messages in between.
      messages
      |> Enum.slice(0, idx)
      |> Enum.reverse()
      |> Enum.find(fn m -> m.role not in [:build, :build_done, :build_failed] end)
      |> case do
        %{role: :tool, tool: tool} when is_binary(tool) ->
          String.ends_with?(tool, "__exec")
        _ ->
          false
      end
    else
      false
    end
  end

  # URL tool result with a closed port — show a clickable link + Open Port button.
  defp chat_msg_port_closed(assigns) do
    content = assigns.msg.content

    # Extract URL and service/container_port from the tool result
    url = case Regex.run(~r{(https?://\S+)}, content) do
      [_, u] -> u
      _ -> nil
    end

    # Tool embeds "open port service/container_port" in the message
    {service, container_port} = case Regex.run(~r{open port (\w+)/(\d+)}, content) do
      [_, s, p] -> {s, p}
      _ -> {"dev", "3000"}
    end

    assigns = assign(assigns, url: url, service: service, container_port: container_port)

    ~H"""
    <div class="pl-10 py-1">
      <div class="inline-flex items-center gap-3 rounded-lg border border-zinc-200 dark:border-zinc-700 px-4 py-2.5">
        <a :if={@url} href={@url} target="_blank" rel="noopener"
          class="text-base text-violet-600 dark:text-violet-400 hover:underline truncate">
          {@url}
        </a>
        <button
          phx-click="open_port_from_chat"
          phx-value-service={@service}
          phx-value-container_port={@container_port}
          class="inline-flex items-center gap-1.5 rounded-md px-3 py-1.5 text-xs font-medium bg-violet-600 hover:bg-violet-700 text-white transition-colors flex-none"
        >
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-3 h-3">
            <path d="M6.22 8.72a.75.75 0 0 0 1.06 1.06l5.22-5.22v1.69a.75.75 0 0 0 1.5 0v-3.5a.75.75 0 0 0-.75-.75h-3.5a.75.75 0 0 0 0 1.5h1.69L6.22 8.72Z" />
            <path d="M3.5 6.75c0-.69.56-1.25 1.25-1.25H7A.75.75 0 0 0 7 4H4.75A2.75 2.75 0 0 0 2 6.75v4.5A2.75 2.75 0 0 0 4.75 14h4.5A2.75 2.75 0 0 0 12 11.25V9a.75.75 0 0 0-1.5 0v2.25c0 .69-.56 1.25-1.25 1.25h-4.5c-.69 0-1.25-.56-1.25-1.25v-4.5Z" />
          </svg>
          Open Port
        </button>
      </div>
    </div>
    """
  end

  # --- Icon buttons for message actions ---

  defp copy_btn(assigns) do
    extra_class = assigns[:class] || ""
    assigns = assign(assigns, :extra_class, extra_class)

    ~H"""
    <button
      id={"copy-#{System.unique_integer([:positive])}"}
      phx-hook="CopySource"
      data-source={@raw_url}
      data-copy="fetch"
      class={"p-1 rounded-md cursor-pointer text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-300 hover:bg-zinc-200 dark:hover:bg-zinc-700 #{@extra_class}"}
      title="Copy"
    >
      <svg class="w-3.5 h-3.5 copy-icon" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor">
        <path d="M5.5 3.5A1.5 1.5 0 0 1 7 2h2.879a1.5 1.5 0 0 1 1.06.44l2.122 2.12a1.5 1.5 0 0 1 .439 1.061V9.5A1.5 1.5 0 0 1 12 11V8.621a3 3 0 0 0-.879-2.121L9 4.379A3 3 0 0 0 6.879 3.5H5.5Z" />
        <path d="M4 5a1.5 1.5 0 0 0-1.5 1.5v6A1.5 1.5 0 0 0 4 14h5a1.5 1.5 0 0 0 1.5-1.5V8.621a1.5 1.5 0 0 0-.44-1.06L7.94 5.439A1.5 1.5 0 0 0 6.878 5H4Z" />
      </svg>
      <svg class="w-3.5 h-3.5 check-icon hidden" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor">
        <path fill-rule="evenodd" d="M12.416 3.376a.75.75 0 0 1 .208 1.04l-5 7.5a.75.75 0 0 1-1.154.114l-3-3a.75.75 0 0 1 1.06-1.06l2.353 2.353 4.493-6.74a.75.75 0 0 1 1.04-.207Z" clip-rule="evenodd" />
      </svg>
    </button>
    """
  end

  defp open_btn(assigns) do
    extra_class = assigns[:class] || ""
    assigns = assign(assigns, :extra_class, extra_class)

    ~H"""
    <a
      href={@url}
      target="_blank"
      rel="noopener"
      class={"p-1 rounded-md text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-300 hover:bg-zinc-200 dark:hover:bg-zinc-700 #{@extra_class}"}
      title="Open"
    >
      <svg class="w-3.5 h-3.5" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor">
        <path d="M6.22 8.72a.75.75 0 0 0 1.06 1.06l5.22-5.22v1.69a.75.75 0 0 0 1.5 0v-3.5a.75.75 0 0 0-.75-.75h-3.5a.75.75 0 0 0 0 1.5h1.69L6.22 8.72Z" />
        <path d="M3.5 6.75c0-.69.56-1.25 1.25-1.25H7A.75.75 0 0 0 7 4H4.75A2.75 2.75 0 0 0 2 6.75v4.5A2.75 2.75 0 0 0 4.75 14h4.5A2.75 2.75 0 0 0 12 11.25V9a.75.75 0 0 0-1.5 0v2.25c0 .69-.56 1.25-1.25 1.25h-4.5c-.69 0-1.25-.56-1.25-1.25v-4.5Z" />
      </svg>
    </a>
    """
  end

  # Detect if an assistant message contains a localhost URL with a
  # registered port. Returns %{service, container_port, host_port, exposed}
  # or nil. Used to show port status inline in the chat.
  defp detect_port_info(content, workspace_id) when is_binary(content) and is_binary(workspace_id) do
    case Regex.run(~r{localhost:(\d+)}, content) do
      [_, port_str] ->
        host_port = String.to_integer(port_str)
        entries = BoomLooper.PortRegistry.list_for_workspace(workspace_id)

        case Enum.find(entries, &(&1.host_port == host_port)) do
          %{service: svc, container_port: cp, exposed: exposed} ->
            %{service: svc, container_port: cp, host_port: host_port, exposed: exposed}
          _ ->
            nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp detect_port_info(_, _), do: nil

  defp msg_url(assigns) do
    msg_id = assigns.msg[:id]
    if msg_id do
      BoomLooperWeb.OutputController.msg_url(assigns.agent_id, msg_id)
    end
  end

  defp raw_url(assigns) do
    msg_id = assigns.msg[:id]
    if msg_id do
      BoomLooperWeb.OutputController.raw_url(assigns.agent_id, msg_id)
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
