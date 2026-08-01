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
  import LoopyardWeb.Components.Icon

  # Same flush-left gutter seam as Messages (returns "" today).
  defp gutter, do: ""

  # Lazy-body gate for collapsible result cards. A collapsed card renders ONLY
  # its summary line — the body (300-line pre, highlighted file card, grep
  # list) enters the DOM when the viewer expands it. Measured: closed bodies
  # were ~17k DOM nodes per heavy turn (177k after ten).
  #
  # Expanded means: the LIVE TAIL (results since the last user prompt — the
  # "watch it work" trust moment, at every detail level), errors, and cards
  # the viewer clicked open (:expanded_results). Scrollback collapses to
  # summaries, which is what bounds the DOM. Callers that don't manage
  # expansion (message tear-off page, operator) pass no :expanded_results
  # and keep the render-everything behavior.
  defp result_expanded?(%{ctx: %{expanded?: e}}), do: e
  defp result_expanded?(_assigns), do: :full

  # In lazy mode the server drives <details open> (body + open arrive in one
  # patch); the native instant-toggle is suppressed so the two can't fight.
  defp lazy?(assigns), do: assigns[:ctx] != nil

  # How many lines of output we keep in the inline DOM. The full text is always
  # one click away via the raw link; this just bounds a pathological 10k-line
  # dump from bloating the page. Generous so "see everything" mostly means it.
  @result_line_cap 300

  # Rows the live tail auto-expands show this many lines; a click upgrades to
  # the full @result_line_cap body.
  @tail_preview_lines 40
  defp body_line_cap(:preview), do: @tail_preview_lines
  defp body_line_cap(_), do: @result_line_cap

  def chat_msg_tool_result(assigns) do
    expanded = result_expanded?(assigns)
    cap = body_line_cap(expanded)
    content = assigns.msg.content
    line_count = if(is_binary(content), do: length(String.split(content, "\n")), else: 1)
    truncated = line_count > cap

    # Body payload is only computed (and rendered) while expanded.
    display =
      if expanded do
        d = Messages.format_tool_result(content)

        if truncated,
          do: d |> String.split("\n") |> Enum.take(cap) |> Enum.join("\n"),
          else: d
      end

    url = Messages.msg_url(assigns)
    raw = Messages.raw_url(assigns)

    assigns =
      assign(assigns,
        display: display,
        expanded?: expanded,
        lazy?: lazy?(assigns),
        truncated: truncated,
        is_error: assigns.msg.is_error,
        line_count: line_count,
        cap: cap,
        url: url,
        raw: raw
      )

    # A one-or-two-line error ("File does not exist.") doesn't need the
    # "error output · 1 line" disclosure ceremony — render it as the same
    # inline red row the :error role uses, so errors read as errors everywhere.
    if assigns.is_error and assigns.line_count <= 2 do
      compact_error(assigns)
    else
      full_result(assigns)
    end
  end

  defp compact_error(assigns) do
    ~H"""
    <div class={[gutter(), "flex items-start gap-2 py-1"]}>
      <div class="w-4 h-4 rounded-sm bg-red-100 dark:bg-red-900/30 flex items-center justify-center flex-none mt-0.5">
        <span class="text-meta font-bold text-red-500">!</span>
      </div>
      <span class="text-body font-mono text-red-600 dark:text-red-400 whitespace-pre-wrap min-w-0">{@display}</span>
    </div>
    """
  end

  defp full_result(assigns) do
    ~H"""
    <details
      class={[gutter(), "py-0.5 group/result"]}
      open={if @lazy?, do: @expanded? != false, else: @detail_level == :trace || @is_error}
    >
      <summary
        class="text-body text-zinc-500 dark:text-zinc-400 cursor-pointer hover:text-zinc-600 dark:hover:text-zinc-400 select-none list-none flex items-center gap-1.5"
        phx-click={@lazy? && "toggle_result"}
        phx-value-msgid={@lazy? && @msg[:id]}
        onclick={@lazy? && "event.preventDefault()"}
      >
        <span class={["transition-transform", @expanded? && "rotate-90"]}>▸</span>
        <span>{if @is_error, do: "error output", else: "output"} · {@line_count} {if @line_count == 1,
          do: "line",
          else: "lines"}</span>
      </summary>
      <pre
        :if={@expanded?}
        class={"mt-1 p-3 rounded-sm text-body md:text-[13px] font-mono leading-snug overflow-x-auto max-h-96 overflow-y-auto whitespace-pre-wrap
    #{if @is_error, do: "bg-red-50 dark:bg-red-950/30 text-red-700 dark:text-red-300", else: "bg-zinc-100 dark:bg-zinc-950 text-zinc-800 dark:text-zinc-300"}"}
      >{Ansi.to_html(@display)}</pre>
      <div :if={@expanded?} class="flex items-center gap-2 mt-1 h-5">
        <p :if={@truncated} class="text-meta text-zinc-500 dark:text-zinc-400">
          ... {@line_count - @cap} more lines — {if @expanded? == :preview,
            do: "click the summary for more",
            else: "open raw to see all"}
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

  # read_file → the FILE CARD: a bordered paper card that reads as "a document",
  # deliberately distinct from the terminal console box (dark body, status dot,
  # command title). Header bar = document icon + basename (emphasized) + its
  # directory (dimmed, truncates first) + language/line-count meta pinned
  # no-wrap on the right. Body = syntax-highlighted code (the `highlight` CSS
  # scope is what activates the makeup token colors) with a sticky line-number
  # gutter, so the numbers hold while long lines scroll horizontally.
  def chat_msg_file_result(assigns) do
    expanded = result_expanded?(assigns)
    call = matching_tool_call(assigns)
    path = call && (call[:input]["path"] || call[:input]["file_path"])
    content = Messages.format_tool_result(assigns.msg.content)
    line_count = length(String.split(content, "\n"))
    language = path && FileType.language(path)

    # The whole body pipeline — native line-number strip, syntax-highlight NIF
    # pass, per-line zip — runs ONLY while expanded. Collapsed cards used to
    # pay it on every transcript re-render (and hold thousands of highlight
    # spans in the DOM).
    {lines, line_count} =
      if expanded do
        # Native harness Read results arrive pre-numbered (" 156→<div…").
        # Strip that prefix and reuse the REAL file line numbers in the gutter.
        {raw_lines, native_nos} = split_read_lines(content)
        n = length(raw_lines)
        stripped = if native_nos, do: Enum.join(raw_lines, "\n"), else: content

        highlight? =
          is_binary(language) and n <= @highlight_max_lines and
            byte_size(stripped) <= @highlight_max_bytes

        rendered =
          if highlight? do
            case Syntax.highlight_lines(stripped, language) do
              nil -> Enum.map(raw_lines, &blank_to_nbsp/1)
              hl -> hl
            end
          else
            Enum.map(raw_lines, &blank_to_nbsp/1)
          end

        numbers = native_nos || (n > 0 && Enum.to_list(1..n)) || []
        {rendered |> Enum.zip(numbers) |> Enum.take(body_line_cap(expanded)), n}
      else
        {[], line_count}
      end

    display_path = path && String.trim_leading(path, "/workspace/")

    assigns =
      assign(assigns,
        basename: (display_path && Path.basename(display_path)) || "file",
        dir: display_path && dirname_or_nil(display_path),
        language: language,
        line_count: line_count,
        lines: lines,
        expanded?: expanded,
        lazy?: lazy?(assigns),
        truncated: line_count > body_line_cap(expanded),
        cap: body_line_cap(expanded),
        file_link: Messages.build_file_link(path, assigns[:workspace_id])
      )

    ~H"""
    <details
      class={[
        gutter(),
        "my-1 group/file rounded-sm border border-zinc-200 dark:border-zinc-800",
        "overflow-hidden bg-brand-paper dark:bg-brand-ink"
      ]}
      open={if @lazy?, do: @expanded? != false, else: @detail_level == :trace}
    >
      <%!-- Four corners, same scheme as the console box: top-left the file's
    IDENTITY (name + dir), top-right the visual control (disclosure);
    meta (language, line count) and actions live in the footer. Keeps
    the header one quiet line. In lazy mode the server drives open
    (body renders on demand) — see result_expanded?/1. --%>
      <summary
        class="flex items-center gap-2 px-3 py-1.5 cursor-pointer select-none list-none bg-brand-paper-shade dark:bg-brand-ink/60 hover:bg-zinc-100 dark:hover:bg-zinc-800/60 transition-colors"
        phx-click={@lazy? && "toggle_result"}
        phx-value-msgid={@lazy? && @msg[:id]}
        onclick={@lazy? && "event.preventDefault()"}
      >
        <.icon name={:document} class="w-3.5 h-3.5 flex-none text-sky-500 dark:text-sky-400" />
        <span class="min-w-0 flex-1 flex items-baseline gap-1.5 font-mono text-body md:text-[13px]">
          <span class="flex-none text-zinc-700 dark:text-zinc-200 font-medium">{@basename}</span>
          <span :if={@dir} class="min-w-0 truncate text-zinc-400 dark:text-zinc-500">{@dir}</span>
        </span>
        <span class="flex-none text-meta text-zinc-400 dark:text-zinc-500 transition-transform group-open/file:rotate-90">
          ▸
        </span>
      </summary>
      <div
        :if={@expanded?}
        class="highlight border-t border-zinc-200 dark:border-zinc-800 max-h-96 overflow-auto text-body md:text-[13px] font-mono leading-relaxed"
      >
        <div :for={{line, i} <- @lines} class="flex min-w-max">
          <span class="flex-none sticky left-0 w-12 pr-3 text-right select-none tabular-nums bg-brand-paper-shade dark:bg-brand-ink border-r border-zinc-100 dark:border-zinc-800 text-zinc-400 dark:text-zinc-600">
            {i}
          </span>
          <code class="whitespace-pre pl-3 pr-3 text-zinc-800 dark:text-zinc-200">{line}</code>
        </div>
      </div>
      <%!-- Footer: meta left (language, size, truncation), actions right.
    Always rendered (it's tiny and carries the collapsed card's meta);
    only the truncation note is gated on expansion — truncation of a
    body that isn't rendered means nothing. --%>
      <div class="flex items-center gap-2 px-3 py-1 border-t border-zinc-200 dark:border-zinc-800 bg-brand-paper-shade dark:bg-brand-ink/60">
        <span
          :if={@language}
          class="flex-none whitespace-nowrap text-meta px-1.5 py-px rounded-sm bg-sky-500/10 text-sky-600 dark:text-sky-400"
        >
          {@language}
        </span>
        <span class="flex-none whitespace-nowrap text-meta tabular-nums text-zinc-400 dark:text-zinc-500">
          {@line_count} {if @line_count == 1, do: "line", else: "lines"}
        </span>
        <span
          :if={@expanded? && @truncated}
          class="text-meta text-zinc-500 dark:text-zinc-400 truncate"
        >
          … {@line_count - @cap} more
        </span>
        <a
          :if={@file_link}
          href={@file_link}
          class="ml-auto flex-none text-meta text-blue-600 dark:text-blue-400 hover:underline"
        >
          Open in file viewer →
        </a>
      </div>
    </details>
    """
  end

  # "lib/foo/bar.ex" → "lib/foo" for the dimmed directory chip; nil when the
  # file sits at the workspace root (no point showing ".").
  defp dirname_or_nil(display_path) do
    case Path.dirname(display_path) do
      "." -> nil
      dir -> dir
    end
  end

  # grep → a match list: each row shows the file:line prefix dimmed and the
  # matched text readable. Non-matching lines (headers, "No matches") pass
  # through as plain rows.
  def chat_msg_grep_result(assigns) do
    expanded = result_expanded?(assigns)
    content = Messages.format_tool_result(assigns.msg.content)

    rows =
      content
      |> String.split("\n")
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&parse_grep_line/1)

    match_count = Enum.count(rows, &match?({:match, _, _, _}, &1))
    call = matching_tool_call(assigns)

    assigns =
      assign(assigns,
        pattern: call && call[:input]["pattern"],
        rows: if(expanded, do: Enum.take(rows, body_line_cap(expanded)), else: []),
        expanded?: expanded,
        lazy?: lazy?(assigns),
        match_count: match_count,
        truncated: length(rows) > body_line_cap(expanded),
        total: length(rows),
        cap: body_line_cap(expanded)
      )

    ~H"""
    <details
      class={[gutter(), "py-0.5 group/grep"]}
      open={if @lazy?, do: @expanded? != false, else: @detail_level == :trace}
    >
      <summary
        class="text-body text-zinc-500 dark:text-zinc-400 cursor-pointer hover:text-zinc-600 dark:hover:text-zinc-400 select-none list-none flex items-center gap-1.5"
        phx-click={@lazy? && "toggle_result"}
        phx-value-msgid={@lazy? && @msg[:id]}
        onclick={@lazy? && "event.preventDefault()"}
      >
        <span class="transition-transform group-open/grep:rotate-90">▸</span>
        <span :if={@pattern} class="font-mono truncate min-w-0">"{@pattern}"</span>
        <span class="flex-none whitespace-nowrap">
          {if @pattern, do: "· ", else: ""}{@match_count} {if @match_count == 1,
            do: "match",
            else: "matches"}
        </span>
      </summary>
      <div
        :if={@expanded?}
        class="mt-1 rounded-sm overflow-hidden bg-zinc-100 dark:bg-zinc-950 border border-zinc-200 dark:border-zinc-800"
      >
        <div class="max-h-96 overflow-auto text-body md:text-[13px] font-mono leading-snug py-1">
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
      <p :if={@expanded? && @truncated} class="text-meta text-zinc-500 dark:text-zinc-400 mt-1">
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

  # Detect the native Read result format — lines " <no>→<text>" — and split
  # it into {stripped_lines, line_numbers}. Detection is TOLERANT (≥90% of
  # lines match): real Read results often carry a couple of stray non-numbered
  # lines (a truncation note, a system-reminder tail), and requiring ALL lines
  # to match made the whole card fall back to double numbering — its own 1..N
  # gutter stacked on the embedded "N→" prefixes, which also fed the arrows to
  # the syntax highlighter. Stray lines are dropped (they're harness chrome,
  # not file content). Plain MCP read_file results (no arrows anywhere) return
  # {lines, nil} and the caller numbers sequentially from 1.
  defp split_read_lines(content) do
    lines =
      content
      |> String.split("\n")
      |> Enum.reverse()
      |> Enum.drop_while(&(&1 == ""))
      |> Enum.reverse()

    parsed = Enum.map(lines, &Regex.run(~r/^\s*(\d+)→(.*)$/, &1))
    matched = Enum.reject(parsed, &is_nil/1)

    if lines != [] and length(matched) / length(lines) >= 0.9 do
      {Enum.map(matched, fn [_, _, text] -> text end),
       Enum.map(matched, fn [_, no, _] -> String.to_integer(no) end)}
    else
      {lines, nil}
    end
  end

  # Mini-app tools (fork/integrate/delete proposals, ask_user — including the
  # harness's NATIVE AskUserQuestion, which reaches the same card via ACP form
  # elicitation) render their outcome in their own interactive card. Public:
  # Messages' :tool clause also suppresses the raw tool-call echo for these.
  @miniapp_tools ~w(propose_fork propose_integrate propose_delete_workspace ask_user AskUserQuestion)

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

  @doc """
  The `%{role: :tool}` call this tool_result belongs to.

  Pairs by `tool_id` (the harness's toolCallId, stamped on both messages by
  StreamHandler) — positional pairing is WRONG when the agent calls tools in
  parallel: every call is emitted first, then every result, so "the nearest
  tool message above me" attributes the FIRST result to the LAST call (an `ls`
  dump rendered as a ruby file card). For legacy messages persisted before
  `tool_id` existed, falls back to order-of-arrival pairing within the turn:
  results arrive in call order, so the Nth result belongs to the Nth call.

  Precomputed ctx (workspace chat) short-circuits the walk — its `call` is
  paired by the same tool_id-first rule in `Transcript.item_contexts/2`.
  """
  def matching_tool_call(%{ctx: %{call: call}}), do: call

  def matching_tool_call(assigns) do
    idx = assigns[:idx]
    messages = assigns[:messages]

    if idx && messages && idx > 0 do
      prior = Enum.slice(messages, 0, idx)

      case assigns.msg[:tool_id] do
        tool_id when is_binary(tool_id) ->
          Enum.find(Enum.reverse(prior), fn m ->
            m[:role] == :tool and m[:tool_id] == tool_id
          end)

        _ ->
          fifo_tool_call(prior)
      end
    end
  end

  # Legacy pairing (messages without tool_id): within the current turn, the
  # result that has N results before it belongs to the call with N calls before
  # it — correct for both sequential [call res call res] and parallel
  # [call call res res] orderings.
  defp fifo_tool_call(prior) do
    turn =
      prior
      |> Enum.reverse()
      |> Enum.take_while(&(&1[:role] != :user))

    calls = turn |> Enum.filter(&(&1[:role] == :tool)) |> Enum.reverse()
    results_before = Enum.count(turn, &(&1[:role] == :tool_result))
    Enum.at(calls, results_before)
  end

  # Check if this tool_result's output was already streamed live as a build
  # message (exec streams into a console box) — rendering it again is redundant.
  # Precomputed ctx (workspace chat) short-circuits the walk.
  def streamed_exec_result?(%{ctx: %{streamed_exec: s}}), do: s

  def streamed_exec_result?(assigns) do
    case matching_tool_call(assigns) do
      %{role: :tool, tool: tool} when is_binary(tool) ->
        String.ends_with?(tool, "__exec")

      _ ->
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
    <div class="py-2">
      <LoopyardWeb.Components.StreamCard.band tone={:needs_you}>
        <LoopyardWeb.Components.StreamCard.header state={:needs_you}>
          <:label>Port closed</:label>
        </LoopyardWeb.Components.StreamCard.header>
        <a
          :if={@url}
          href={@url}
          target="_blank"
          rel="noopener"
          class="text-body block truncate text-violet-600 dark:text-violet-400 hover:underline mb-3"
        >
          {@url}
        </a>
        <button
          phx-click="open_port_from_chat"
          phx-value-service={@service}
          phx-value-container_port={@container_port}
          class="focus-ring text-body inline-flex items-center gap-1.5 rounded-sm px-3.5 py-1.5 font-medium bg-violet-600 hover:bg-violet-700 text-white shadow-sm transition-colors flex-none"
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
      </LoopyardWeb.Components.StreamCard.band>
    </div>
    """
  end
end
