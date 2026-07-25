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
  # Streaming markdown: renders the live reply block-by-block, freezing completed
  # blocks (phx-update="ignore") and re-diffing only the active block per token —
  # so we get live-rendered markdown WITHOUT the O(reply) re-render firehose that
  # d0c34c5's client-append avoided. See streaming_bubble/1.
  use PhoenixStreamdown

  import LoopyardWeb.Components.LogViewer, only: [log_inline: 1]
  import LoopyardWeb.Components.DiffView, only: [diff: 1]
  import LoopyardWeb.Components.Icon

  alias Loopyard.Agent.ToolKind
  alias LoopyardWeb.Components.Ansi

  alias LoopyardWeb.Components.ToolSummary
  alias LoopyardWeb.Live.WorkspaceLive.Messages.Cards
  alias LoopyardWeb.Live.WorkspaceLive.Messages.Transcript

  # Transcript-structure helpers live in Messages.Transcript (size-cap split);
  # re-exposed so chat_panel + the transcript-layout tests are unchanged.
  defdelegate transcript_groups(messages), to: Transcript
  defdelegate transcript_sections(messages), to: Transcript
  defdelegate item_contexts(messages, expanded_results), to: Transcript
  defdelegate visible_sections(messages, expanded_results, live_from), to: Transcript
  defdelegate section_key(section), to: Transcript

  # The Copy / Open hover buttons live in Messages.Actions (size-cap split);
  # imported so the `<.copy_btn/>` / `<.open_btn/>` chat_msg calls are unchanged.
  import LoopyardWeb.Live.WorkspaceLive.Messages.Actions, only: [copy_btn: 1, open_btn: 1]

  # Tool-result renderers + suppress-echo predicates — split out for the
  # module-size invariant; the :tool_result dispatcher below stays here.
  import LoopyardWeb.Live.WorkspaceLive.Messages.ToolResults,
    only: [
      chat_msg_tool_result: 1,
      tool_result_kind: 1,
      chat_msg_file_result: 1,
      chat_msg_grep_result: 1,
      chat_msg_port_closed: 1,
      console_command_result?: 1,
      chat_msg_console_result: 1,
      matching_tool_call: 1,
      miniapp_tool?: 1,
      miniapp_tool_result?: 1,
      streamed_exec_result?: 1
    ]

  # Tools that render their OWN interactive card (role: :approval / :question) —
  # the card IS the human-facing surface, so we suppress the raw tool-call echo
  # and the tool-result echo for them (list + predicate live in ToolResults).

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
  # A live "quote" of ANOTHER agent's chat — the chat-in-chat mini-app.
  def chat_msg(%{msg: %{role: :embed}} = assigns), do: Cards.agent_embed(assigns)

  def chat_msg(%{msg: %{role: :user}} = assigns) do
    assigns = assign(assigns, :url, msg_url(assigns))
    assigns = assign(assigns, :raw, raw_url(assigns))
    # Label = the workstation identity (chat.ex passes it); `active?` marks the
    # prompt the agent is currently answering. Defaults keep non-transcript
    # callers (tests, build-row reuse) working without passing them.
    assigns = assign_new(assigns, :user_label, fn -> "You" end)
    assigns = assign_new(assigns, :active?, fn -> false end)

    # The big "chapter-break" air belongs at human<->machine boundaries only.
    # Consecutive human messages (a flurry / queued batch) GROUP into one purple
    # area: the "You" label + the sticky header show on the FIRST only, and the
    # bands butt together (tight padding, no gap) so they read as a single block,
    # not N separate cards.
    first? = prev_role(assigns) != :user

    assigns =
      assign(assigns,
        show_user_label: first?,
        sticky_class: if(first?, do: "sticky top-0 z-20", else: ""),
        # Keep the chapter-break air TIGHT: a large top margin on the next prompt
        # meant the previous (sticky) prompt hung over a big empty gap before the
        # next one pushed it up. Small, even spacing → prompts hand off flush.
        band_top: if(first?, do: "mt-5 md:mt-6 pt-4 md:pt-5", else: "mt-0 pt-2"),
        band_bottom:
          cond do
            # The running prompt hands straight off to its live response: no
            # bottom margin, so the rail continues unbroken into the streaming
            # content flush below it. Padding matches the TOP (pt-4/5) — the
            # bigger completed-band padding read as a gap inside the active band.
            assigns[:active?] -> "mb-0 pb-4 md:pb-5"
            next_role(assigns) == :user -> "mb-0 pb-3"
            true -> "mb-4 md:mb-5 pb-6 md:pb-7"
          end
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
        "-mx-4 md:-mx-6 px-4 md:px-6 lg:px-8 group/msg transition-colors",
        # The prompt being answered right now reads stronger (deeper wash + a
        # GLOWING violet left rail — same .chat-live-rail as the streaming
        # content below, so the running prompt and its live response read as one
        # continuous, lit timeline).
        (@active? &&
           "bg-violet-200 dark:bg-[#332a54] border-l-2 border-violet-500 dark:border-violet-400 chat-live-rail") ||
          "bg-violet-100 dark:bg-[#2b2348] border-l-2 border-transparent",
        @sticky_class,
        @band_top,
        @band_bottom
      ]}
      id={"msg-user-#{@msg[:id] || hash_content(@msg.content)}"}
    >
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0">
          <div
            :if={@show_user_label}
            class="flex items-center gap-2 mb-2"
          >
            <span class="chat-meta inline-flex items-center gap-1.5 font-semibold uppercase tracking-wide text-violet-600 dark:text-violet-300">
              <.icon name={:user} class="w-3.5 h-3.5 flex-none self-center" /> {@user_label}
            </span>
            <span
              :if={@msg[:timestamp]}
              class="chat-meta text-violet-500/80 dark:text-violet-300/60"
            >
              {Calendar.strftime(@msg.timestamp, "%b %-d, %-I:%M %p")}
            </span>
          </div>
          <%!-- Clamp to a few lines: the prompt is a sticky HEADER, so a long
               paste must stay header-sized (full text via the ↗ link). --%>
          <div class="markdown-body human-prompt text-zinc-800 dark:text-zinc-100 max-w-3xl line-clamp-3">
            {Loopyard.Markdown.to_html(@msg.content)}
          </div>
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
      <div class={[gutter(), "py-0.5"]}>
        <div class="markdown-body text-zinc-800 dark:text-zinc-100 max-w-2xl">
          {Loopyard.Markdown.to_html(@rendered_content)}
        </div>
        <div :if={@port_info && !@port_info.exposed} class="mt-1.5 flex items-center gap-2 py-1">
          <div class="w-1.5 h-1.5 rounded-full flex-none bg-amber-400"></div>
          <span class="text-sm text-zinc-500 dark:text-zinc-400">{@port_info.service} port closed</span>
          <button
            phx-click="open_port_from_chat"
            phx-value-service={@port_info.service}
            phx-value-container_port={@port_info.container_port}
            class="inline-flex items-center px-1.5 rounded text-xs font-medium text-zinc-500 dark:text-zinc-400 hover:bg-zinc-200 dark:hover:bg-zinc-700 transition-colors"
          >
            Open Port
          </button>
        </div>
        <div :if={@port_info && @port_info.exposed} class="mt-1.5 flex items-center gap-2 py-1">
          <div class="w-1.5 h-1.5 rounded-full flex-none bg-emerald-500"></div>
          <span class="text-sm text-zinc-500 dark:text-zinc-400">{@port_info.service}</span>
          <a
            href={"http://#{assigns[:host] || "localhost"}:#{@port_info.host_port}"}
            target="_blank"
            rel="noopener noreferrer"
            class="inline-flex items-center px-2 rounded text-sm font-mono font-medium bg-emerald-500/15 text-emerald-600 dark:text-emerald-400 hover:bg-emerald-500/25 transition-colors"
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

  def chat_msg(%{msg: %{role: :tool}} = assigns) do
    cond do
      # :chat hides the agent's mechanics — switch up a level to see them again.
      assigns.detail_level == :chat -> ~H"<div></div>"
      # Mini-app tools own their own card — don't also echo the raw tool call.
      miniapp_tool?(assigns.msg[:tool] || "") -> ~H"<div></div>"
      # exec / docker_compose render as a console box whose TITLE is the command —
      # the raw "$ cmd" tool row would just show the command a second time. Suppress
      # it so the console window is the single representation of the command.
      msg_kind(assigns.msg) == :command -> ~H"<div></div>"
      true -> render_tool_call(assigns)
    end
  end

  def chat_msg(%{msg: %{role: :thinking}, detail_level: :chat} = assigns) do
    ~H"<div></div>"
  end

  def chat_msg(%{msg: %{role: :thinking}} = assigns) do
    ~H"""
    <details class={[gutter(), "my-1 group"]} open={@detail_level == :trace}>
      <summary class="text-sm text-zinc-500 dark:text-zinc-400 cursor-pointer hover:text-zinc-600 dark:hover:text-zinc-400 select-none">
        💭 Reasoning
      </summary>
      <%!-- Prose thinking, not machine output — matches the live streaming_thinking
           pre (text-sm, no mono) so the block doesn't change typeface when the
           turn finalizes. --%>
      <pre class="mt-1 p-3 rounded-lg text-sm bg-zinc-50 dark:bg-zinc-900 text-zinc-500 dark:text-zinc-400 whitespace-pre-wrap leading-relaxed max-h-60 overflow-y-auto">{@msg.content}</pre>
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

      # CLI-command tool (git) that didn't stream — render it as the SAME
      # console box as exec / docker builds: command + output + exit status.
      console_command_result?(assigns) ->
        chat_msg_console_result(assigns)

      # A FAILED result is an error message, not content — never dress it as a
      # file/grep card (a failed Read's "File does not exist." is not ruby).
      assigns.msg.is_error ->
        chat_msg_tool_result(assigns)

      true ->
        # Rich cards for the tools whose output has an obvious shape: a file read
        # becomes syntax-highlighted code with a filename header; a grep becomes
        # a match list with dimmed file:line prefixes. Everything else keeps the
        # plain collapsible <pre>. Classified off the matching :tool call.
        case tool_result_kind(assigns) do
          :read -> chat_msg_file_result(assigns)
          :grep -> chat_msg_grep_result(assigns)
          _ -> chat_msg_tool_result(assigns)
        end
    end
  end

  def chat_msg(%{msg: %{role: :error}} = assigns) do
    ~H"""
    <div class={[gutter(), "flex items-start gap-2 py-1"]}>
      <div class="w-4 h-4 rounded bg-red-100 dark:bg-red-900/30 flex items-center justify-center flex-none mt-0.5">
        <span class="text-xs font-bold text-red-500">!</span>
      </div>
      <span class="chat-sub text-red-600 dark:text-red-400">{Ansi.to_html(@msg.content)}</span>
      <span class="text-xs text-zinc-300 dark:text-zinc-600 flex-none">
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

    # Wrap in a plain <div>: this is the ROOT of a stateful LiveComponent
    # (MessageRowComponent), which requires a single STATIC root. log_inline's own
    # root carries a dynamic id (System.unique_integer) + phx-hook, so it can't be
    # `.root: true` on its own — the static wrapper gives the component a clean root.
    ~H"""
    <div>
      <.log_inline content={@msg.content} status={:done} raw_url={@link} title={@msg[:title]} />
    </div>
    """
  end

  def chat_msg(%{msg: %{role: :build_failed}} = assigns) do
    assigns = assign(assigns, :link, msg_url(assigns))

    ~H"""
    <div>
      <.log_inline
        content={@msg.content}
        status={:failed}
        raw_url={@link}
        title={@msg[:title]}
        exit_code={@msg[:exit_code]}
      />
    </div>
    """
  end

  def chat_msg(%{msg: %{role: :system, content: content}} = assigns) do
    # Hide raw struct dumps and SDK noise — not human-readable
    if is_binary(content) &&
         (String.starts_with?(content, "[init]") || String.starts_with?(content, "%Claude") ||
            String.contains?(content, "SystemMessage")) do
      ~H"<div></div>"
    else
      # Meta notes (compaction, CLI crash/restart, context refresh) are
      # house-keeping, not conversation — keep them a quiet aside: tiny, muted
      # italic, no bullet, so you can SEE them happen without them competing with
      # what the agent actually said. (Comment lives here, NOT as a leading HEEX
      # comment inside ~H — that would make this a non-single-static root and
      # crash the stateful MessageRowComponent.)
      ~H"""
      <div class="py-1.5 text-center text-zinc-400/70 dark:text-zinc-600">
        <span
          class="text-sm italic leading-relaxed"
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

  # Neutral kind for a :tool message. Prefer the kind the harness stamped on the
  # message via the ToolKind seam; fall back to classifying the raw name for
  # messages persisted before kinds were threaded through. The UI classifies by
  # KIND, never by matching raw tool names — that's what keeps a new harness's
  # tool vocabulary rendering correctly without touching this module.
  defp msg_kind(%{tool_kind: kind}) when not is_nil(kind), do: kind
  defp msg_kind(%{tool: tool}) when is_binary(tool), do: ToolKind.classify(tool)
  defp msg_kind(_), do: :generic

  defp render_tool_call(assigns) do
    tool_name = assigns.msg[:tool] || ""
    input = assigns.msg.input || %{}

    is_edit = msg_kind(assigns.msg) == :edit

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
    <div class={[gutter(), "py-1"]}>
      <div class="flex items-center gap-2">
        <span class={["w-1.5 h-1.5 rounded-full flex-none", tool_dot(@tool_name)]}></span>
        <a
          :if={@file_link}
          href={@file_link}
          class="chat-sub text-blue-600 dark:text-blue-400 hover:underline"
        >
          {@summary}
        </a>
        <span :if={!@file_link} class="chat-sub text-zinc-600 dark:text-zinc-400">{@summary}</span>
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

  attr :streaming_text, :string, default: ""

  def streaming_bubble(assigns) do
    # Server-side incremental markdown, client-appended. The server
    # (`Markdown.Stream`, per connection) buffers raw tokens and emits COMPLETE
    # blocks as safe HTML; the `StreamMarkdown` hook appends each block into
    # [data-stream-blocks] ONCE (never re-diffed → no DOM thrash) and shows the
    # current incomplete block as a plain [data-stream-tail]. phx-update="ignore"
    # keeps LiveView off this subtree; the `:if` at the call site removes it
    # between turns so each stream starts empty. The finalized assistant Message
    # re-renders through the SAME renderer, so there's no snap when it replaces
    # this element.
    ~H"""
    <div class="py-0.5 mt-2" id="streaming-msg" phx-update="ignore" phx-hook="StreamMarkdown">
      <div class="markdown-body text-zinc-800 dark:text-zinc-100 max-w-2xl">
        <div data-stream-blocks></div>
        <div data-stream-tail></div>
      </div>
    </div>
    """
  end

  def streaming_thinking(assigns) do
    # The agent's live reasoning — flows on the spine, not a bubble. Quietly set
    # apart (muted, italic-feel via the label) since it's inner monologue.
    # Client-appended like streaming_bubble (event "stream_thinking_delta").
    ~H"""
    <div
      class="py-1"
      id="streaming-thinking"
      phx-update="ignore"
      phx-hook="StreamAppend"
      data-stream-event="stream_thinking_delta"
    >
      <p class="text-sm text-zinc-500 dark:text-zinc-400 mb-1 font-medium uppercase tracking-wide">
        Thinking
      </p>
      <pre
        data-stream-target
        class="text-sm text-zinc-500 dark:text-zinc-400 whitespace-pre-wrap leading-relaxed max-h-56 overflow-y-auto"
      ></pre>
    </div>
    """
  end

  # --- Internal helpers ---

  # Left edge for agent rows. Every row — prose, tool calls, tool results,
  # logs, system lines — sits FLUSH against this same gutter so the whole
  # transcript reads as one clean left column (no per-row indentation; rows
  # stay distinct via their markers/color, not by hanging in from the edge).
  # Kept as a seam in case rows ever need a shared base class.
  defp gutter, do: ""

  # Role of the message immediately before/after this one — used to keep the big
  # band air at human<->machine boundaries only (tight between consecutive humans).
  # Precomputed ctx (workspace chat) beats the legacy walk (message tear-off
  # page passes messages+idx and no ctx).
  defp prev_role(%{ctx: %{prev_role: r}}), do: r

  defp prev_role(%{idx: idx, messages: messages}) when is_integer(idx) and idx > 0,
    do: Enum.at(messages, idx - 1, %{})[:role]

  defp prev_role(_), do: nil

  defp next_role(%{ctx: %{next_role: r}}), do: r

  defp next_role(%{idx: idx, messages: messages}) when is_integer(idx) and is_list(messages),
    do: Enum.at(messages, idx + 1, %{})[:role]

  defp next_role(_), do: nil

  # Category tint for a tool-call's gutter dot — a quiet scan aid: you read the
  # color column to see the SHAPE of what happened (writes vs runs vs reads)
  # without reading the text. Tint = signal, kept muted.
  defp tool_dot(tool) when is_binary(tool) do
    cond do
      ToolKind.classify(tool) in [:edit, :write] ->
        "bg-violet-400"

      ToolKind.command?(tool) ->
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

  def build_file_link(nil, _workspace_id), do: nil
  def build_file_link(_path, nil), do: nil

  def build_file_link(path, workspace_id) when is_binary(path) do
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

  def build_file_link(_, _), do: nil

  defp preceded_by_edit?(%{ctx: %{preceded_by_edit: p}}), do: p

  defp preceded_by_edit?(assigns) do
    case matching_tool_call(assigns) do
      %{role: :tool} = m -> msg_kind(m) == :edit
      _ -> false
    end
  end

  def msg_url(assigns) do
    msg_id = assigns.msg[:id]

    if msg_id do
      LoopyardWeb.OutputController.msg_url(assigns.agent_id, msg_id)
    end
  end

  def raw_url(assigns) do
    msg_id = assigns.msg[:id]

    if msg_id do
      LoopyardWeb.OutputController.raw_url(assigns.agent_id, msg_id)
    end
  end

  defp hash_content(content) when is_binary(content) do
    :erlang.phash2(content, 0xFFFFFF) |> Integer.to_string(16)
  end

  def format_tool_result(content) do
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
