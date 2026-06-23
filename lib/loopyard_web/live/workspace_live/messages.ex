defmodule LoopyardWeb.Live.WorkspaceLive.Messages do
  @moduledoc """
  Chat message rendering — every `chat_msg/1` clause and its supporting
  helpers, extracted from `LoopyardWeb.WorkspaceLive` to keep that file
  navigable.

  Each clause in `chat_msg/1` handles one message role (user, assistant,
  tool, tool_result, error, build, build_done, build_failed, system).
  Plus `streaming_bubble/1` for the in-progress assistant text.

  These are public function components — `LoopyardWeb.WorkspaceLive`
  imports them and renders `<.chat_msg ... />` inline.

  This file is intentionally template-only. It does NOT touch sockets,
  GenServers, or PubSub — only assigns. That makes it safe to test in
  isolation and trivial to reuse outside the chat panel if we ever
  want to (e.g., a message permalink page).
  """
  use Phoenix.Component

  import LoopyardWeb.Components.LogViewer, only: [log_inline: 1]
  import LoopyardWeb.Components.DiffView, only: [diff: 1]
  import LoopyardWeb.Components.Icon

  alias LoopyardWeb.Components.Ansi

  alias LoopyardWeb.Components.ToolSummary
  alias LoopyardWeb.Live.WorkspaceLive.Messages.Cards

  # Tools that render their OWN interactive card (role: :approval / :question) —
  # the card IS the human-facing surface, so we suppress the raw tool-call echo
  # and the tool-result echo for them. Matched by suffix against the fully
  # qualified MCP tool name (e.g. "mcp__loopyard-container__propose_fork").
  @miniapp_tools ~w(propose_fork propose_integrate propose_delete_workspace ask_user)

  attr :msg, :map, required: true
  attr :idx, :integer, required: true
  attr :messages, :list, default: []
  attr :agent_id, :string, required: true
  attr :workspace_id, :string, default: nil
  attr :host, :string, default: "localhost"
  # Disclosure level — how much of the agent's inner work to show:
  #   :trace   — everything, reasoning + tool outputs expanded (default, max trust)
  #   :actions — reasoning + tool calls; outputs collapsed (click to drill down)
  #   :chat    — just the conversation; activity hidden (still drillable by switching back)
  attr :detail_level, :atom, default: :trace

  # The two interactive mini-app cards live in Messages.Cards (extracted to keep
  # this file under its line cap). chat_msg delegates the matching roles.
  def chat_msg(%{msg: %{role: :question}} = assigns), do: Cards.question_card(assigns)
  def chat_msg(%{msg: %{role: :approval}} = assigns), do: Cards.approval_card(assigns)
  def chat_msg(%{msg: %{role: :secret_request}} = assigns), do: Cards.secret_card(assigns)

  def chat_msg(%{msg: %{role: :user}} = assigns) do
    assigns = assign(assigns, :url, msg_url(assigns))
    assigns = assign(assigns, :raw, raw_url(assigns))

    # The big "chapter-break" air belongs at human<->machine boundaries only.
    # Back-to-back human messages (accidental keystrokes, rapid-fire follow-ups)
    # stay tight — no cavernous gap between two of your own lines.
    assigns =
      assign(assigns,
        band_top: if(prev_role(assigns) == :user, do: "mt-2", else: "mt-16 md:mt-24"),
        band_bottom: if(next_role(assigns) == :user, do: "mb-2", else: "mb-10 md:mb-14")
      )

    # The human prompt is a full-bleed purple band, not a bubble. It's `sticky`
    # to the top of its <section> (chat_panel wraps each prompt + its response in
    # one), so the prompt that owns the response you're reading stays pinned —
    # scroll through a long answer and you never lose the question. `-mx` makes
    # the shade reach the column edges; `backdrop-blur` keeps it legible as the
    # response scrolls underneath.
    ~H"""
    <div
      class={[
        "sticky top-0 z-20 -mx-4 md:-mx-6 px-4 md:px-6 py-4 bg-violet-100 dark:bg-[#2b2348] group/msg",
        @band_top,
        @band_bottom
      ]}
      id={"msg-user-#{@msg[:id] || hash_content(@msg.content)}"}
    >
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0">
          <div class="flex items-center gap-1.5 text-[11px] font-semibold uppercase tracking-wide text-violet-600 dark:text-violet-300 mb-1.5">
            <.icon name={:user} class="w-3.5 h-3.5 flex-none" /> You
          </div>
          <%!-- Clamp to a few lines: the prompt is a sticky HEADER, so a long
               paste must stay header-sized (full text via the ↗ link). --%>
          <div class="markdown-body text-sm md:text-base leading-relaxed text-zinc-800 dark:text-zinc-100 max-w-3xl line-clamp-3">{Loopyard.Markdown.to_html(@msg.content)}</div>
        </div>
        <div class="flex items-center gap-1 flex-none opacity-0 group-hover/msg:opacity-100 transition-opacity">
          <.copy_btn :if={@raw} raw_url={@raw} />
          <.open_btn :if={@url} url={@url} />
        </div>
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

    assigns =
      assign(
        assigns,
        :rendered_content,
        rewrite_localhost_urls(assigns.msg.content, assigns[:host])
      )

    assigns =
      assign(assigns, :port_info, detect_port_info(assigns.msg.content, assigns[:workspace_id]))

    # The agent writes a CONTINUOUS transcript: no bubble, no per-message avatar.
    # The run wrapper (chat_panel) owns the "● Claude" header + the faint left
    # spine; this clause just contributes flowing prose into that gutter.
    ~H"""
    <div class="group/msg" id={"msg-#{@msg[:id] || hash_content(@msg.content)}"}>
      <div class={[gutter(), "pl-7 py-0.5"]}>
        <div class="markdown-body text-[15px] leading-relaxed text-zinc-800 dark:text-zinc-100 max-w-2xl">{Loopyard.Markdown.to_html(@rendered_content)}</div>
        <div :if={@port_info && !@port_info.exposed} class="mt-1.5 flex items-center gap-2 py-1">
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
        <div :if={@port_info && @port_info.exposed} class="mt-1.5 flex items-center gap-2 py-1">
          <div class="w-1.5 h-1.5 rounded-full flex-none bg-emerald-500"></div>
          <span class="text-xs text-zinc-500 dark:text-zinc-400">{@port_info.service}</span>
          <a
            href={"http://#{assigns[:host] || "localhost"}:#{@port_info.host_port}"}
            target="_blank"
            rel="noopener noreferrer"
            class="inline-flex items-center px-2 rounded text-xs font-mono font-medium bg-emerald-500/15 text-emerald-600 dark:text-emerald-400 hover:bg-emerald-500/25 transition-colors"
          >
            :{@port_info.host_port}
          </a>
        </div>
        <div class="flex items-center gap-1 mt-0.5 h-5 opacity-0 group-hover/msg:opacity-100 transition-opacity">
          <.copy_btn :if={@raw} raw_url={@raw} />
          <.open_btn :if={@url} url={@url} />
        </div>
      </div>
    </div>
    """
  end

  @doc "The agent's identity marker — rendered once at the top of each run."
  attr :timestamp, :any, default: nil

  def run_header(assigns) do
    ~H"""
    <div class="flex items-center gap-2 mt-3 mb-1.5">
      <span class="flex-none w-5 h-5 rounded-full bg-violet-100 dark:bg-violet-900/40 flex items-center justify-center">
        <.icon name={:sparkle} class="w-3 h-3 text-violet-600 dark:text-violet-400" />
      </span>
      <span class="text-sm font-semibold text-zinc-700 dark:text-zinc-200">Claude</span>
      <span :if={@timestamp} class="text-xs text-zinc-400 dark:text-zinc-500">
        · {Calendar.strftime(@timestamp, "%H:%M")}
      </span>
    </div>
    """
  end

  def chat_msg(%{msg: %{role: :tool}} = assigns) do
    cond do
      # :chat hides the agent's mechanics — switch up a level to see them again.
      assigns.detail_level == :chat -> ~H"<div></div>"
      # Mini-app tools own their own card — don't also echo the raw tool call.
      miniapp_tool?(assigns.msg[:tool] || "") -> ~H"<div></div>"
      # exec / docker_compose render as a console box whose TITLE is the command —
      # the raw "$ cmd" tool row would just show the command a second time. Suppress
      # it so the console window is the single representation of the command.
      console_command_tool?(assigns.msg[:tool]) -> ~H"<div></div>"
      true -> render_tool_call(assigns)
    end
  end

  defp console_command_tool?(tool) when is_binary(tool),
    do: String.ends_with?(tool, "__exec") or String.ends_with?(tool, "__docker_compose")

  defp console_command_tool?(_), do: false

  defp render_tool_call(assigns) do
    tool_name = assigns.msg[:tool] || ""
    input = assigns.msg.input || %{}

    is_edit =
      String.ends_with?(tool_name, "__edit") || String.ends_with?(tool_name, "__multi_edit")

    old_str = if is_edit, do: input["old_string"]
    new_str = if is_edit, do: input["new_string"]

    # Build file link for tools that operate on files
    file_path = input["path"] || input["file_path"]
    file_link = build_file_link(file_path, assigns[:workspace_id])

    assigns =
      assigns
      |> assign(:summary, ToolSummary.summarize(assigns.msg.tool, input))
      |> assign(is_edit: is_edit, old_str: old_str, new_str: new_str)
      |> assign(:file_link, file_link)
      |> assign(:tool_name, tool_name)

    # Quiet, scannable row: a small category-tinted dot (violet=write/edit,
    # green=run, blue=read/search) in the gutter, then the verb+object summary.
    # Color is reserved for SIGNAL — the dot's category and the blue of a
    # clickable file link. A plain summary stays muted, not blue.
    ~H"""
    <div class={[gutter(), "py-1 pl-5"]}>
      <div class="flex items-center gap-2">
        <span class={["w-1.5 h-1.5 rounded-full flex-none", tool_dot(@tool_name)]}></span>
        <a
          :if={@file_link}
          href={@file_link}
          class="text-sm text-blue-600 dark:text-blue-400 hover:underline"
        >
          {@summary}
        </a>
        <span :if={!@file_link} class="text-sm text-zinc-600 dark:text-zinc-400">{@summary}</span>
      </div>
      <.diff
        :if={@is_edit && @old_str && @new_str}
        old={@old_str}
        new={@new_str}
        path={@msg.input["path"]}
        link={@file_link}
      />
    </div>
    """
  end

  def chat_msg(%{msg: %{role: :thinking}, detail_level: :chat} = assigns) do
    ~H"<div></div>"
  end

  def chat_msg(%{msg: %{role: :thinking}} = assigns) do
    ~H"""
    <details class={[gutter(), "pl-5 my-1 group"]} open={@detail_level == :trace}>
      <summary class="text-xs text-zinc-400 dark:text-zinc-500 cursor-pointer hover:text-zinc-600 dark:hover:text-zinc-400 select-none">
        💭 Reasoning
      </summary>
      <pre class="mt-1 p-3 rounded-lg text-xs font-mono bg-zinc-50 dark:bg-zinc-900 text-zinc-500 dark:text-zinc-400 whitespace-pre-wrap max-h-60 overflow-y-auto">{@msg.content}</pre>
    </details>
    """
  end

  def chat_msg(%{msg: %{role: :tool_result}} = assigns) do
    content = assigns.msg.content

    cond do
      # :chat collapses all the mechanics away — bump the level to drill back in.
      assigns.detail_level == :chat ->
        ~H"<div></div>"

      is_binary(content) && String.contains?(content, "completed with no output") ->
        ~H"<div></div>"

      # Mini-app tools (propose_fork, ask_user, …) show their outcome in their
      # own card — the tool-result echo below it is the "card thing" we don't want.
      miniapp_tool_result?(assigns) ->
        ~H"<div></div>"

      # exec output is already shown in the streaming build message above —
      # don't render it twice.
      streamed_exec_result?(assigns) ->
        ~H"<div></div>"

      # edit diff is shown inline on the tool call — don't repeat
      preceded_by_edit?(assigns) ->
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
    <div class={[gutter(), "flex items-start gap-2 py-1 pl-5"]}>
      <div class="w-4 h-4 rounded bg-red-100 dark:bg-red-900/30 flex items-center justify-center flex-none mt-0.5">
        <span class="text-[10px] font-bold text-red-500">!</span>
      </div>
      <span class="text-xs text-red-600 dark:text-red-400">{Ansi.to_html(@msg.content)}</span>
      <span class="text-[10px] text-zinc-300 dark:text-zinc-600 flex-none">
        {Calendar.strftime(@msg.timestamp, "%H:%M:%S")}
      </span>
    </div>
    """
  end

  def chat_msg(%{msg: %{role: :build}} = assigns) do
    assigns = assign(assigns, :link, msg_url(assigns))

    ~H"""
    <.log_inline
      content={@msg.content}
      status={:building}
      raw_url={@link}
      title={@msg[:title]}
      started={@msg[:timestamp]}
    />
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
    <.log_inline
      content={@msg.content}
      status={:failed}
      raw_url={@link}
      title={@msg[:title]}
      exit_code={@msg[:exit_code]}
    />
    """
  end

  def chat_msg(%{msg: %{role: :system, content: content}} = assigns) do
    # Hide raw struct dumps and SDK noise — not human-readable
    if is_binary(content) &&
         (String.starts_with?(content, "[init]") || String.starts_with?(content, "%Claude") ||
            String.contains?(content, "SystemMessage")) do
      ~H"<div></div>"
    else
      ~H"""
      <%!-- Meta notes (compaction, CLI crash/restart, context refresh) are
           house-keeping, not conversation — keep them a quiet aside: tiny, muted,
           a small dot in the gutter, so you can SEE them happen without them
           competing with what the agent actually said. --%>
      <div class={[gutter(), "py-1 pl-7 flex items-baseline gap-1.5 text-zinc-400/70 dark:text-zinc-600"]}>
        <span aria-hidden="true" class="flex-none select-none leading-none">·</span>
        <span
          class="text-[11px] italic leading-relaxed"
          id={"system-msg-#{@msg[:id] || hash_content(@msg.content)}"}
        >
          {@msg.content}
        </span>
      </div>
      """
    end
  end

  def chat_msg(assigns) do
    ~H"""
    <div></div>
    """
  end

  attr :text, :string, required: true

  def streaming_bubble(assigns) do
    ~H"""
    <div class={[gutter(), "pl-7 py-0.5 mt-2"]} id="streaming-msg">
      <div class="markdown-body text-[15px] leading-relaxed text-zinc-800 dark:text-zinc-100 max-w-2xl">{Loopyard.Markdown.to_html(@text)}<span class="inline-block w-1.5 h-4 bg-violet-500 animate-pulse ml-0.5 align-middle"></span></div>
    </div>
    """
  end

  def streaming_thinking(assigns) do
    # The agent's live reasoning — flows on the spine, not a bubble. Quietly set
    # apart (muted, italic-feel via the label) since it's inner monologue.
    ~H"""
    <div class="pl-7 py-1">
      <p class="text-[11px] text-zinc-400 dark:text-zinc-500 mb-1 font-medium uppercase tracking-wide">
        Thinking
      </p>
      <pre class="text-sm text-zinc-500 dark:text-zinc-400 whitespace-pre-wrap leading-relaxed max-h-56 overflow-y-auto">{@text}</pre>
      <span class="inline-block w-1.5 h-3.5 bg-zinc-400 animate-pulse ml-0.5 align-middle"></span>
    </div>
    """
  end

  # --- Internal helpers ---

  # Left padding alignment for agent rows. The faint spine itself now lives on
  # the RUN WRAPPER (chat_panel), so a run reads as one unbroken line; rows just
  # keep their content inset (action icons hang at `pl-5`, just left of the
  # `pl-7` prose). Kept as a seam in case rows ever need a shared base class.
  defp gutter, do: ""

  # Role of the message immediately before/after this one — used to keep the big
  # band air at human<->machine boundaries only (tight between consecutive humans).
  defp prev_role(%{idx: idx, messages: messages}) when is_integer(idx) and idx > 0,
    do: Enum.at(messages, idx - 1, %{})[:role]

  defp prev_role(_), do: nil

  defp next_role(%{idx: idx, messages: messages}) when is_integer(idx) and is_list(messages),
    do: Enum.at(messages, idx + 1, %{})[:role]

  defp next_role(_), do: nil

  # Category tint for a tool-call's gutter dot — a quiet scan aid: you read the
  # color column to see the SHAPE of what happened (writes vs runs vs reads)
  # without reading the text. Tint = signal, kept muted.
  defp tool_dot(tool) when is_binary(tool) do
    cond do
      String.ends_with?(tool, "__edit") or String.ends_with?(tool, "__multi_edit") or
          String.ends_with?(tool, "__write_file") ->
        "bg-violet-400"

      String.ends_with?(tool, "__exec") or String.ends_with?(tool, "__docker_compose") ->
        "bg-emerald-400"

      String.contains?(tool, "read") or String.contains?(tool, "tree") or
        String.contains?(tool, "search") or String.contains?(tool, "grep") or
          String.contains?(tool, "logs") ->
        "bg-blue-400"

      true ->
        "bg-zinc-300 dark:bg-zinc-600"
    end
  end

  defp tool_dot(_), do: "bg-zinc-300 dark:bg-zinc-600"

  @doc """
  Group the message list into transcript segments for the run-spine layout.

  Returns an ordered list of:
    * `{:run, [{msg, idx}]}` — consecutive agent-authored messages that share
      ONE spine + ONE "Claude" header.
    * `{:break, {msg, idx}}` — a human-facing message (user bubble, or a
      question/approval card) that stands alone and breaks the run.

  Indices are the original positions in `messages` (so `chat_msg` look-back
  helpers still work).
  """
  def transcript_groups(messages) do
    messages
    |> Enum.with_index()
    |> Enum.reduce([], fn {msg, idx}, groups ->
      cond do
        break_msg?(msg) ->
          [{:break, {msg, idx}} | groups]

        match?([{:run, _} | _], groups) ->
          [{:run, items} | rest] = groups
          [{:run, [{msg, idx} | items]} | rest]

        true ->
          [{:run, [{msg, idx}]} | groups]
      end
    end)
    |> Enum.map(fn
      {:run, items} -> {:run, Enum.reverse(items)}
      other -> other
    end)
    |> Enum.reverse()
  end

  # Human-facing roles break a run: the user bubble, and the ask_user /
  # approval cards (which are answered by a human).
  defp break_msg?(%{role: role}), do: role in [:user, :question, :approval]
  defp break_msg?(_), do: false

  @doc """
  Group the transcript into SECTIONS for the sticky-prompt layout.

  Each section is `%{prompt: {msg, idx} | nil, body: [group]}` where a new
  section begins at every human **prompt** (`:user`) and `body` is the
  transcript groups (runs + question/approval cards) that answer it. The leading
  section before the first prompt has `prompt: nil`.

  The point: chat_panel wraps each section in a `<section>` and makes the prompt
  `sticky` — so the prompt that owns the response you're scrolling stays pinned
  at the top until the next prompt's section takes over.
  """
  def transcript_sections(messages) do
    messages
    |> transcript_groups()
    |> Enum.reduce([], fn group, sections ->
      case group do
        {:break, {%{role: :user}, _idx}} = prompt ->
          {:break, p} = prompt
          [%{prompt: p, body: []} | sections]

        other ->
          case sections do
            [%{body: body} = sec | rest] -> [%{sec | body: [other | body]} | rest]
            [] -> [%{prompt: nil, body: [other]}]
          end
      end
    end)
    |> Enum.map(fn %{body: body} = sec -> %{sec | body: Enum.reverse(body)} end)
    |> Enum.reverse()
  end

  # How many lines of output we keep in the inline DOM. The full text is always
  # one click away via the raw link; this just bounds a pathological 10k-line
  # dump from bloating the page. Generous so "see everything" mostly means it.
  @result_line_cap 300

  defp chat_msg_tool_result(assigns) do
    content = assigns.msg.content
    display = format_tool_result(content)
    lines = String.split(display, "\n")
    truncated = length(lines) > @result_line_cap
    display = if truncated, do: Enum.take(lines, @result_line_cap) |> Enum.join("\n"), else: display
    url = msg_url(assigns)
    raw = raw_url(assigns)

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
    <details class={[gutter(), "pl-5 py-0.5 group/result"]} open={@detail_level == :trace || @is_error}>
      <summary class="text-[11px] text-zinc-400 dark:text-zinc-500 cursor-pointer hover:text-zinc-600 dark:hover:text-zinc-400 select-none list-none flex items-center gap-1.5">
        <span class="transition-transform group-open/result:rotate-90">▸</span>
        <span>{if @is_error, do: "error output", else: "output"} · {@line_count} {if @line_count == 1, do: "line", else: "lines"}</span>
      </summary>
      <pre class={"mt-1 p-3 rounded-lg text-xs font-mono overflow-x-auto max-h-96 overflow-y-auto whitespace-pre-wrap
                   #{if @is_error, do: "bg-red-50 dark:bg-red-950/30 text-red-700 dark:text-red-300", else: "bg-zinc-100 dark:bg-zinc-950 text-zinc-800 dark:text-zinc-300"}"}>{Ansi.to_html(@display)}</pre>
      <div class="flex items-center gap-2 mt-1 h-5">
        <p :if={@truncated} class="text-[10px] text-zinc-400 dark:text-zinc-500">
          ... {@line_count - @cap} more lines — open raw to see all
        </p>
        <.copy_btn :if={@raw} raw_url={@raw} />
        <.open_btn :if={@url} url={@url} />
      </div>
    </details>
    """
  end

  defp miniapp_tool?(tool) when is_binary(tool),
    do: Enum.any?(@miniapp_tools, &String.ends_with?(tool, &1))

  defp miniapp_tool?(_), do: false

  # A tool_result whose matching :tool call is a mini-app tool — its outcome
  # already lives in the approval/question card, so suppress the echo.
  defp miniapp_tool_result?(assigns) do
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
    <div class={[gutter(), "pl-5 py-1"]}>
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
          class="inline-flex items-center gap-1.5 rounded-md px-3 py-1.5 text-xs font-medium bg-violet-600 hover:bg-violet-700 text-white transition-colors flex-none"
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
      <.icon name={:copy} class="w-3.5 h-3.5 copy-icon" />
      <.icon name={:check} class="w-3.5 h-3.5 check-icon hidden" />
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
      <.icon name={:external} class="w-3.5 h-3.5" />
    </a>
    """
  end

  # Detect if an assistant message contains a localhost URL with a
  # registered port. Returns %{service, container_port, host_port, exposed}
  # or nil. Used to show port status inline in the chat.
  defp detect_port_info(content, workspace_id)
       when is_binary(content) and is_binary(workspace_id) do
    case Regex.run(~r{localhost:(\d+)}, content) do
      [_, port_str] ->
        host_port = String.to_integer(port_str)
        entries = Loopyard.PortRegistry.list_for_workspace(workspace_id)

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

  defp build_file_link(nil, _workspace_id), do: nil
  defp build_file_link(_path, nil), do: nil

  defp build_file_link(path, workspace_id) when is_binary(path) do
    # Path comes from agent tool input — strip the workspace prefix, reject
    # traversal segments, and URL-encode each remaining segment so `?`, `#`,
    # `&`, spaces etc. can't smuggle a query string into the link.
    segments =
      path
      |> String.trim_leading("/workspace/")
      |> String.trim_leading("/")
      |> String.split("/", trim: true)

    cond do
      segments == [] ->
        nil

      Enum.any?(segments, &(&1 == ".." or &1 == ".")) ->
        nil

      true ->
        case :ets.lookup(:workspace_registry, workspace_id) do
          [{_, %{project_id: project_id}}] ->
            volume = Loopyard.Workspace.volume_name_for(workspace_id)

            encoded =
              Enum.map_join(segments, "/", fn seg -> URI.encode(seg, &URI.char_unreserved?/1) end)

            "/projects/#{URI.encode(project_id, &URI.char_unreserved?/1)}" <>
              "/workspaces/#{URI.encode(workspace_id, &URI.char_unreserved?/1)}" <>
              "/volumes/#{URI.encode(volume, &URI.char_unreserved?/1)}" <>
              "/files/#{encoded}"

          _ ->
            nil
        end
    end
  rescue
    _ -> nil
  end

  defp build_file_link(_, _), do: nil

  defp preceded_by_edit?(assigns) do
    idx = assigns[:idx]
    messages = assigns[:messages]

    if idx && messages && idx > 0 do
      messages
      |> Enum.slice(0, idx)
      |> Enum.reverse()
      |> Enum.find(fn m -> m.role not in [:build, :build_done, :build_failed] end)
      |> case do
        %{role: :tool, tool: tool} when is_binary(tool) ->
          String.ends_with?(tool, "__edit") || String.ends_with?(tool, "__multi_edit")

        _ ->
          false
      end
    else
      false
    end
  end

  defp msg_url(assigns) do
    msg_id = assigns.msg[:id]

    if msg_id do
      LoopyardWeb.OutputController.msg_url(assigns.agent_id, msg_id)
    end
  end

  defp raw_url(assigns) do
    msg_id = assigns.msg[:id]

    if msg_id do
      LoopyardWeb.OutputController.raw_url(assigns.agent_id, msg_id)
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
  # plain localhost without a port is left alone (it's a Loopyard-relative
  # path that the browser handles).
  defp rewrite_localhost_urls(content, nil), do: content
  defp rewrite_localhost_urls(content, "localhost"), do: content

  defp rewrite_localhost_urls(content, host) when is_binary(content) and is_binary(host) do
    String.replace(content, "http://localhost:", "http://#{host}:")
  end

  defp rewrite_localhost_urls(content, _host), do: content
end
