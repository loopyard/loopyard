defmodule LoopyardWeb.Live.WorkspaceLive.Messages.ToolResults do
  @moduledoc """
  Tool-RESULT renderers for the chat transcript: the plain collapsible output,
  the syntax-highlighted file-read card, the grep match list, the closed-port
  card, and the suppress-echo predicates the `chat_msg(:tool_result)`
  dispatcher (in `Messages`) uses. Split out of `Messages` for the module-size
  invariant. Shared plumbing (msg_url/raw_url/format_tool_result/…) stays in
  `Messages` and is called qualified — no import cycle.
  """
  use Phoenix.Component

  alias Loopyard.Agent.ToolKind
  alias LoopyardWeb.Components.Ansi
  alias LoopyardWeb.Live.WorkspaceLive.Messages
  alias LoopyardWeb.Live.WorkspaceLive.Components.Viewers.{FileType, Syntax}

  import LoopyardWeb.Live.WorkspaceLive.Messages.Actions, only: [copy_btn: 1, open_btn: 1]
  import LoopyardWeb.Components.LogViewer, only: [log_inline: 1]

  # Same flush-left gutter seam as Messages (returns "" today).
  defp gutter, do: ""

  # How many lines of output we keep in the inline DOM. The full text is always
  # one click away via the raw link; this just bounds a pathological 10k-line
  # dump from bloating the page. Generous so "see everything" mostly means it.
  @result_line_cap 300

  def chat_msg_tool_result(assigns) do
    content = assigns.msg.content
    display = Messages.format_tool_result(content)
    lines = String.split(display, "\n")
    truncated = length(lines) > @result_line_cap

    display =
      if truncated, do: Enum.take(lines, @result_line_cap) |> Enum.join("\n"), else: display

    url = Messages.msg_url(assigns)
    raw = Messages.raw_url(assigns)

    assigns =
      assign(assigns,
        display: display,
        truncated: truncated,
        is_error: assigns.msg.is_error,
        line_count: length(lines),
        cap: @result_line_cap,
        url: url,
        raw: raw
      )

    ~H"""
    <details
      class={[gutter(), "py-0.5 group/result"]}
      open={@detail_level == :trace || @is_error}
    >
      <summary class="text-sm text-zinc-500 dark:text-zinc-400 cursor-pointer hover:text-zinc-600 dark:hover:text-zinc-400 select-none list-none flex items-center gap-1.5">
        <span class="transition-transform group-open/result:rotate-90">▸</span>
        <span>{if @is_error, do: "error output", else: "output"} · {@line_count} {if @line_count == 1,
          do: "line",
          else: "lines"}</span>
      </summary>
      <pre class={"mt-1 p-3 rounded-lg text-sm font-mono overflow-x-auto max-h-96 overflow-y-auto whitespace-pre-wrap
                   #{if @is_error, do: "bg-red-50 dark:bg-red-950/30 text-red-700 dark:text-red-300", else: "bg-zinc-100 dark:bg-zinc-950 text-zinc-800 dark:text-zinc-300"}"}>{Ansi.to_html(@display)}</pre>
      <div class="flex items-center gap-2 mt-1 h-5">
        <p :if={@truncated} class="text-xs text-zinc-500 dark:text-zinc-400">
          ... {@line_count - @cap} more lines — open raw to see all
        </p>
        <.copy_btn :if={@raw} raw_url={@raw} />
        <.open_btn :if={@url} url={@url} />
      </div>
    </details>
    """
  end

  @doc """
  True when this tool_result came from a CLI-COMMAND tool that ran a shell
  command but did NOT stream (git today) — so its output should render as the
  SAME console box as exec / docker builds (`log_inline`): the command as the
  title bar, the output in the body, a green `exit 0` / red `exit ✗` status.
  Exec/docker already stream that way; this brings git in line.
  """
  def console_command_result?(assigns) do
    # Any command-kind tool whose result reaches here (exec/docker were already
    # hidden as streamed builds by the dispatcher) → render its result as the
    # console box. Classified by the neutral ToolKind seam, not by tool name.
    call_kind(matching_tool_call(assigns)) == :command
  end

  @doc "Render a CLI-command tool_result as the shared console box (see console_command_result?/1)."
  def chat_msg_console_result(assigns) do
    call = matching_tool_call(assigns)

    assigns =
      assign(assigns,
        command: console_command_label(call),
        cli_status: if(assigns.msg.is_error, do: :failed, else: :done),
        link: Messages.msg_url(assigns)
      )

    ~H"""
    <div class={gutter()}>
      <.log_inline content={@msg.content} status={@cli_status} title={@command} raw_url={@link} />
    </div>
    """
  end

  # The "$"-style command line for the console title bar, reconstructed from the
  # matching tool call. Native "Bash" carries the FULL command; the loopyard git
  # MCP tool carries just the subcommand ("status", "diff main"), so prefix it.
  defp console_command_label(%{tool: "Bash", input: input}),
    do: to_string(input["command"] || "")

  defp console_command_label(%{tool: tool, input: input}) when is_binary(tool) do
    cond do
      String.ends_with?(tool, "__git") -> "git " <> to_string(input["command"] || "")
      true -> to_string(input["command"] || tool)
    end
  end

  defp console_command_label(_), do: nil

  # Classify a tool_result by the tool that produced it, so the dispatcher can
  # pick a rich renderer. Only the shapes we have a card for; everything else is
  # `:generic` and keeps the plain <pre>.
  def tool_result_kind(assigns) do
    # Rich result cards are keyed off the neutral tool KIND, so native ACP tools
    # ("Read"/"Grep") and loopyard MCP tools ("__read_file"/"__grep") — and any
    # future harness that stamps the same kind — read identically. Only :read and
    # :grep have result cards; everything else keeps the plain <pre>.
    case call_kind(matching_tool_call(assigns)) do
      :read -> :read
      :grep -> :grep
      _ -> :generic
    end
  end

  # Neutral kind of the tool CALL that produced this result — prefer the kind the
  # harness stamped on the message, fall back to classifying the raw name.
  defp call_kind(%{tool_kind: kind}) when not is_nil(kind), do: kind
  defp call_kind(%{tool: tool}) when is_binary(tool), do: ToolKind.classify(tool)
  defp call_kind(_), do: :generic

  # Cost guards for inline syntax highlighting — highlighting is a synchronous
  # Rust NIF pass, and the transcript re-renders, so a huge file read must fall
  # back to plain text instead of re-tokenizing on every render.
  @highlight_max_lines 500
  @highlight_max_bytes 80_000

  # read_file → a syntax-highlighted code card with a filename header and a link
  # into the file viewer. Same collapsible affordance as the plain result, but
  # the body is highlighted code with line numbers.
  def chat_msg_file_result(assigns) do
    call = matching_tool_call(assigns)
    path = call && (call.input["path"] || call.input["file_path"])
    content = Messages.format_tool_result(assigns.msg.content)
    raw_lines = String.split(content, "\n")
    line_count = length(raw_lines)
    language = path && FileType.language(path)

    highlight? =
      is_binary(language) and line_count <= @highlight_max_lines and
        byte_size(content) <= @highlight_max_bytes

    lines =
      if highlight? do
        case Syntax.highlight_lines(content, language) do
          nil -> Enum.map(raw_lines, &blank_to_nbsp/1)
          hl -> hl
        end
      else
        Enum.map(raw_lines, &blank_to_nbsp/1)
      end
      |> Enum.take(@result_line_cap)
      |> Enum.with_index(1)

    assigns =
      assign(assigns,
        path: path,
        language: language,
        line_count: line_count,
        lines: lines,
        truncated: line_count > @result_line_cap,
        cap: @result_line_cap,
        file_link: Messages.build_file_link(path, assigns[:workspace_id])
      )

    ~H"""
    <details class={[gutter(), "py-0.5 group/file"]} open={@detail_level == :trace}>
      <summary class="text-sm text-zinc-500 dark:text-zinc-400 cursor-pointer hover:text-zinc-600 dark:hover:text-zinc-400 select-none list-none flex items-center gap-1.5">
        <span class="transition-transform group-open/file:rotate-90">▸</span>
        <span class="font-mono text-zinc-500 dark:text-zinc-400 truncate">{@path || "file"}</span>
        <span :if={@language} class="text-zinc-500 dark:text-zinc-400">· {@language}</span>
        <span class="text-zinc-500 dark:text-zinc-400">· {@line_count} lines</span>
      </summary>
      <div class="mt-1 rounded-lg overflow-hidden bg-zinc-100 dark:bg-zinc-950 border border-zinc-200 dark:border-zinc-800">
        <div class="max-h-96 overflow-auto text-sm font-mono leading-relaxed">
          <div :for={{line, i} <- @lines} class="flex">
            <span class="flex-none w-10 pr-3 text-right text-zinc-500 dark:text-zinc-400 select-none tabular-nums">
              {i}
            </span>
            <code class="whitespace-pre text-zinc-800 dark:text-zinc-200">{line}</code>
          </div>
        </div>
      </div>
      <div class="flex items-center gap-2 mt-1 h-5">
        <p :if={@truncated} class="text-xs text-zinc-500 dark:text-zinc-400">
          ... {@line_count - @cap} more lines
        </p>
        <a
          :if={@file_link}
          href={@file_link}
          class="text-sm text-blue-600 dark:text-blue-400 hover:underline"
        >
          Open in file viewer →
        </a>
      </div>
    </details>
    """
  end

  # grep → a match list: each row shows the file:line prefix dimmed and the
  # matched text readable. Non-matching lines (headers, "No matches") pass
  # through as plain rows.
  def chat_msg_grep_result(assigns) do
    content = Messages.format_tool_result(assigns.msg.content)

    rows =
      content
      |> String.split("\n")
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&parse_grep_line/1)

    match_count = Enum.count(rows, &match?({:match, _, _, _}, &1))

    assigns =
      assign(assigns,
        rows: Enum.take(rows, @result_line_cap),
        match_count: match_count,
        truncated: length(rows) > @result_line_cap,
        total: length(rows),
        cap: @result_line_cap
      )

    ~H"""
    <details class={[gutter(), "py-0.5 group/grep"]} open={@detail_level == :trace}>
      <summary class="text-sm text-zinc-500 dark:text-zinc-400 cursor-pointer hover:text-zinc-600 dark:hover:text-zinc-400 select-none list-none flex items-center gap-1.5">
        <span class="transition-transform group-open/grep:rotate-90">▸</span>
        <span>{@match_count} {if @match_count == 1, do: "match", else: "matches"}</span>
      </summary>
      <div class="mt-1 rounded-lg overflow-hidden bg-zinc-100 dark:bg-zinc-950 border border-zinc-200 dark:border-zinc-800">
        <div class="max-h-96 overflow-auto text-sm font-mono leading-relaxed py-1">
          <div
            :for={row <- @rows}
            class="flex gap-2 px-3 hover:bg-zinc-200/50 dark:hover:bg-zinc-800/50"
          >
            <%= case row do %>
              <% {:match, path, lno, text} -> %>
                <span class="flex-none text-zinc-500 dark:text-zinc-400 select-none">
                  {path}<span class="text-violet-500 dark:text-violet-400">:{lno}</span>
                </span>
                <span class="whitespace-pre text-zinc-800 dark:text-zinc-200 truncate">{text}</span>
              <% {:plain, line} -> %>
                <span class="text-zinc-500 dark:text-zinc-400">{line}</span>
            <% end %>
          </div>
        </div>
      </div>
      <p :if={@truncated} class="text-xs text-zinc-500 dark:text-zinc-400 mt-1">
        ... {@total - @cap} more lines
      </p>
    </details>
    """
  end

  # A grep output line "path:lineno: content" → structured; anything else plain.
  defp parse_grep_line(line) do
    case Regex.run(~r/^(.+?):(\d+):\s?(.*)$/, line) do
      [_, path, lno, text] -> {:match, path, lno, text}
      _ -> {:plain, line}
    end
  end

  # Keep blank source lines from collapsing to zero height in the code card.
  defp blank_to_nbsp(""), do: Phoenix.HTML.raw("&nbsp;")
  defp blank_to_nbsp(line), do: line

  # Mini-app tools (fork/integrate/delete proposals, ask_user) render their
  # outcome in their own interactive card. Public: Messages' :tool clause also
  # suppresses the raw tool-call echo for these.
  @miniapp_tools ~w(propose_fork propose_integrate propose_delete_workspace ask_user)

  def miniapp_tool?(tool) when is_binary(tool),
    do: Enum.any?(@miniapp_tools, &String.ends_with?(tool, &1))

  def miniapp_tool?(_), do: false

  # A tool_result whose matching :tool call is a mini-app tool — its outcome
  # already lives in the approval/question card, so suppress the echo.
  def miniapp_tool_result?(assigns) do
    case matching_tool_call(assigns) do
      %{role: :tool, tool: tool} when is_binary(tool) -> miniapp_tool?(tool)
      _ -> false
    end
  end

  # Walk backwards from a tool_result to the :tool call it belongs to, skipping
  # any streamed build messages in between.
  defp matching_tool_call(assigns) do
    idx = assigns[:idx]
    messages = assigns[:messages]

    if idx && messages && idx > 0 do
      messages
      |> Enum.slice(0, idx)
      |> Enum.reverse()
      |> Enum.find(fn m -> m.role not in [:build, :build_done, :build_failed] end)
    end
  end

  # Check if this tool_result has a streamed build message above it —
  # the output was already shown live, so rendering it again is redundant.
  # Message order is: :tool (exec) → :build_done (streamed output) → :tool_result
  def streamed_exec_result?(assigns) do
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
  def chat_msg_port_closed(assigns) do
    content = assigns.msg.content

    # Extract URL and service/container_port from the tool result
    url =
      case Regex.run(~r{(https?://\S+)}, content) do
        [_, u] -> u
        _ -> nil
      end

    # Tool embeds "open port service/container_port" in the message
    {service, container_port} =
      case Regex.run(~r{open port (\w+)/(\d+)}, content) do
        [_, s, p] -> {s, p}
        _ -> {"dev", "3000"}
      end

    assigns = assign(assigns, url: url, service: service, container_port: container_port)

    ~H"""
    <div class={[gutter(), "py-1"]}>
      <div class="inline-flex items-center gap-3 rounded-lg border border-zinc-200 dark:border-zinc-700 px-4 py-2.5">
        <a
          :if={@url}
          href={@url}
          target="_blank"
          rel="noopener"
          class="text-base text-violet-600 dark:text-violet-400 hover:underline truncate"
        >
          {@url}
        </a>
        <button
          phx-click="open_port_from_chat"
          phx-value-service={@service}
          phx-value-container_port={@container_port}
          class="inline-flex items-center gap-1.5 rounded-md px-3 py-1.5 text-sm font-medium bg-violet-600 hover:bg-violet-700 text-white transition-colors flex-none"
        >
          <svg
            xmlns="http://www.w3.org/2000/svg"
            viewBox="0 0 16 16"
            fill="currentColor"
            class="w-3 h-3"
          >
            <path d="M6.22 8.72a.75.75 0 0 0 1.06 1.06l5.22-5.22v1.69a.75.75 0 0 0 1.5 0v-3.5a.75.75 0 0 0-.75-.75h-3.5a.75.75 0 0 0 0 1.5h1.69L6.22 8.72Z" />
            <path d="M3.5 6.75c0-.69.56-1.25 1.25-1.25H7A.75.75 0 0 0 7 4H4.75A2.75 2.75 0 0 0 2 6.75v4.5A2.75 2.75 0 0 0 4.75 14h4.5A2.75 2.75 0 0 0 12 11.25V9a.75.75 0 0 0-1.5 0v2.25c0 .69-.56 1.25-1.25 1.25h-4.5c-.69 0-1.25-.56-1.25-1.25v-4.5Z" />
          </svg>
          Open Port
        </button>
      </div>
    </div>
    """
  end
end
