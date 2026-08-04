defmodule LoopyardWeb.Live.WorkspaceLive.Components.Chat do
  @moduledoc """
  Chat panel components: agent_view, chat_panel, container_panel.

  The header component group (chat_header, agent_header, detail_level_control)
  lives in the `Chat.Header` sub-module and the pure status predicates in
  `Chat.Status` — both split out to keep this file under its size cap. The
  public components are re-exposed here via `defdelegate` so callers keep
  using `Chat.*` / the blanket import unchanged.
  """
  use Phoenix.Component

  import LoopyardWeb.Live.WorkspaceLive.Messages,
    only: [streaming_bubble: 1, streaming_thinking: 1]

  import LoopyardWeb.Components.Icon

  import LoopyardWeb.Live.WorkspaceLive.Components.Chat.Status,
    only: [
      workstation_label: 1,
      active_prompt_ids: 1,
      awaiting_answer?: 1,
      awaiting_approval?: 1,
      building?: 1,
      live_status_mode: 1,
      active_turn_cutoff: 1
    ]

  alias LoopyardWeb.Live.WorkspaceLive.Components.Chat.Header
  alias LoopyardWeb.Live.WorkspaceLive.Components.ChatStatus

  # The live-status presentation (thinking feed, live tail, Reasoning Bar) lives
  # in the ChatStatus sub-module to keep this file under its size cap. Re-expose
  # the public component functions so chat_panel's `<.thinking_indicator/>` /
  # `<.live_status/>` calls and the `Chat.current_turn_activity/1` tests are
  # unchanged.
  defdelegate thinking_indicator(assigns), to: ChatStatus
  defdelegate live_status(assigns), to: ChatStatus
  defdelegate reasoning_bar(assigns), to: ChatStatus
  defdelegate current_turn_activity(messages), to: ChatStatus

  # The header component group lives in Chat.Header — re-exposed so the blanket
  # `import Chat` in Components (and `<.chat_header/>` / `<.agent_header/>`
  # call sites) keeps working unchanged.
  defdelegate chat_header(assigns), to: Header
  defdelegate agent_header(assigns), to: Header
  defdelegate detail_level_control(assigns), to: Header

  # --- Agent View ---

  def agent_view(assigns) do
    ~H"""
    <div class="flex-1 flex min-h-0">
      <%!-- Center pane. The mobile category switcher lives in the top back bar
    now; the agent's Info folds into the header — so this pane is just the
    chat (or the container view). Agents / Services / Volumes are reached
    by the tab bar, which routes services/volumes to their own screens. --%>
      <div class="flex-1 flex flex-col min-w-0 min-h-0">
        <.agent_header
          agent={@selected_agent}
          has_container={@has_container}
          base_path={@base_path}
          changes={@changes}
          detail_level={@detail_level}
        />
        <.chat_panel
          :if={@tab != :container}
          static?={assigns[:static?] || false}
          messages={@messages}
          streaming_text={@streaming_text}
          streaming_thinking={@streaming_thinking}
          agent={@selected_agent}
          workspace_id={@workspace.id}
          host={@host}
          thinking_word={@thinking_word}
          has_more_messages={@has_more_messages}
          window_tail?={@window_tail?}
          detail_level={@detail_level}
          expanded_results={@expanded_results}
        />
        <.container_panel
          :if={@tab == :container}
          env={@container_env}
          logs={@container_logs}
          log_service={@container_log_service}
          has_container={@has_container}
        />
      </div>
    </div>
    """
  end

  # --- Chat Panel ---

  def chat_panel(assigns) do
    # While the agent is working, its in-progress tool calls are shown in the
    # live activity feed (thinking_indicator) — so suppress the SAME rows here
    # to avoid double-listing. They render inline normally once the turn ends.
    assigns = assign(assigns, :live_tool_from, active_turn_cutoff(assigns))
    assigns = assign_new(assigns, :window_tail?, fn -> true end)

    # The human's label is the WORKSTATION identity (e.g. "Brad"), not a generic
    # "You" — the messages are sent under that identity. Stable per agent, so it
    # adds no per-row diff churn. `active_prompt_id` is the id of the prompt the
    # agent is CURRENTLY answering (last user message while it's working) — the
    # :user band styles that one stronger. Passed as a per-row boolean so only the
    # active row (and the one it hands off from) ever re-diffs.
    assigns =
      assign(assigns,
        user_label: workstation_label(assigns.agent),
        active_prompt_ids: active_prompt_ids(assigns)
      )

    # Precompute the section structure ONCE per render, with per-row context
    # baked into each item ({msg, idx, ctx}) and live-feed-suppressed rows
    # already filtered out. Rows must not reference any per-append-changing
    # assign (@item_ctx map, @live_tool_from) — that re-dirtied every row on
    # every append. Keyed tracking compares the loop items themselves.
    alias LoopyardWeb.Live.WorkspaceLive.Messages

    assigns =
      assign(
        assigns,
        :transcript_sections,
        Messages.visible_sections(
          assigns.messages,
          assigns[:expanded_results] || MapSet.new(),
          assigns.live_tool_from
        )
      )

    # Rows reference @agent_id, never @agent.id: @agent is re-assigned on
    # every append (last_activity_at), which would mark every row's agent_id
    # expression dirty. assign/3 value-compares, so this stays unchanged.
    assigns = assign(assigns, :agent_id, assigns.agent.id)

    ~H"""
    <%!-- PerfProbe: client-health beacon (frame gaps / DOM / heap → EventLog).
    Lives on the chat panel because that's the surface with the perf
    history — see the hook in app.js. --%>
    <div class="relative flex-1 flex flex-col min-h-0" id="chat-perf-probe" phx-hook="PerfProbe">
      <%!-- Windowed transcript: when you've scrolled up into history, the live
    tail isn't loaded. This snaps you back to the newest messages. --%>
      <button
        :if={not @window_tail?}
        phx-click="load_latest"
        class="absolute bottom-3 left-1/2 -translate-x-1/2 z-10 inline-flex items-center gap-1.5 rounded-full bg-violet-600 text-white text-lead font-medium px-3.5 py-1.5 shadow-lg shadow-violet-900/20 hover:bg-violet-700 transition-colors"
      >
        Jump to latest
        <svg viewBox="0 0 20 20" fill="currentColor" class="w-3.5 h-3.5">
          <path
            fill-rule="evenodd"
            d="M10 3a.75.75 0 0 1 .75.75v9.19l3.72-3.72a.75.75 0 1 1 1.06 1.06l-5 5a.75.75 0 0 1-1.06 0l-5-5a.75.75 0 1 1 1.06-1.06l3.72 3.72V3.75A.75.75 0 0 1 10 3Z"
            clip-rule="evenodd"
          />
        </svg>
      </button>
      <%!-- scroll-smooth: the auto-tail (ScrollBottom hook nudges scrollTop as the
    agent streams) animates instead of jumping, so following the thinking
    glides. Pure CSS — honors prefers-reduced-motion automatically. --%>
      <div id="messages" class="flex-1 overflow-y-auto flex flex-col pb-4 scroll-pt-32">
        <%!-- Normal flow, TOP-aligned. This used to be `mt-auto`, which
    bottom-anchors the column so the newest message sits just above the
    input on first paint. That's right for a long transcript and wrong
    for a short one: with less content than viewport, the whole
    conversation was shoved to the bottom of the screen and the
    `sticky top-0` prompt had nothing to pin against — it was already
    down by the composer. Top alignment fixes the short case, and the
    long case is unaffected because ScrollBottom scrolls to the end on
    mount and `_initialReveal` masks it, which is what actually prevents
    the slide-down jank.
    Normal flow (NOT col-reverse) is what lets the human prompts
    `position: sticky` to the top of their section. --%>
        <%!-- The document column: transcript + composer share this centered,
    capped measure so their gutters LINE UP. The outer div is a
    full-width flex child that bottom-anchors the transcript (mt-auto);
    the inner is the centered measure. Centering a BLOCK (mx-auto in
    normal flow) is what reliably lines the transcript's gutters up with
    the composer below — mx-auto on a direct flex-column child does NOT
    center it. The column is FULL-WIDTH (bands touch the pane edges via
    negative margins that mirror this padding exactly) until the `wide`
    ultrawide cutover, where it caps + centers — a full-bleed bar across
    an ultrawide monitor is the only case that earns the side gap. --%>
        <div class="w-full">
          <div class="space-y-3 w-full wide:max-w-3xl mx-auto px-4 md:px-6">
            <%!-- Progressive loader: while there's older history above the window,
    a soft shimmer sits at the very top. Scroll into it and load_more
    fetches the next batch (prepended below this, so it stays put);
    when you reach the start it disappears. Gentler than a hard
    "Loading…" flash. --%>
            <div :if={assigns[:has_more_messages]} class="space-y-2.5 py-3" aria-hidden="true">
              <div class="h-3 w-20 rounded-sm bg-zinc-200/80 dark:bg-zinc-700/50 animate-pulse"></div>
              <div class="h-3.5 w-3/4 rounded-sm bg-zinc-200/70 dark:bg-zinc-700/40 animate-pulse">
              </div>
              <div class="h-3.5 w-1/2 rounded-sm bg-zinc-200/70 dark:bg-zinc-700/40 animate-pulse">
              </div>
            </div>
            <%!-- Split into SECTIONS: each human prompt + the response it owns. The
    prompt is `sticky top-0` WITHIN its <section>, so it pins while you
    scroll its response and then RELEASES at the section boundary as the
    next prompt's section takes over — prompts replace each other
    instead of stacking. Pure CSS; the normal-flow scroll (not
    col-reverse) is what makes the per-section sticky pin flush. --%>
            <%!-- BOTH loops are :key-ed (section → prompt msg id, row → msg id):
    without keys, LiveView diffs comprehensions by index, so the
    window sliding at the cap re-shipped every row on every append
    (~850KB/turn measured). Rows are LiveComponents (diffed by id +
    assigns equality) with per-row precomputed ctx — never the whole
    @messages list. Live-feed suppression happens server-side in
    Messages.visible_sections/3. --%>
            <%!-- No rail on the active turn — the deeper wash on the running
    prompt band + the live status row mark it. (Rails kept
    misaligning across band/tail/breakpoints; not worth it.) --%>
            <%!-- FIRST CONTACT. A workspace that has just been cloned lands here
    with a Ready agent and an empty transcript — the payoff moment of
    onboarding, saying nothing. The user does not yet know that asking
    the agent to set up the dev environment is the next move, so say it.
    Disappears the instant there's any history; a working chat must not
    keep coaching. --%>
            <div
              :if={@transcript_sections == []}
              class="py-10 md:py-14 text-center"
            >
              <p class="text-lead text-zinc-600 dark:text-zinc-300">
                This agent can read and write the code, run commands, and build the dev
                environment for you.
              </p>
              <p class="text-body text-zinc-500 dark:text-zinc-400 mt-2">
                A good first ask:
                <span class="italic">"set up the dev environment and get it running"</span>
              </p>
            </div>

            <section :for={section <- @transcript_sections} :key={Messages.section_key(section)}>
              <%= if section.prompt do %>
                <% {pmsg, pidx, pctx} = section.prompt %>
                <.live_component
                  module={LoopyardWeb.Live.WorkspaceLive.MessageRowComponent}
                  id={"mr-#{pmsg[:id] || pidx}"}
                  msg={pmsg}
                  idx={pidx}
                  ctx={pctx}
                  agent_id={@agent_id}
                  workspace_id={@workspace_id}
                  host={@host}
                  user_label={@user_label}
                  active?={MapSet.member?(@active_prompt_ids, pmsg[:id])}
                  detail_level={@detail_level}
                />
              <% end %>
              <%= for group <- section.body do %>
                <%= case group do %>
                  <% {:break, {msg, idx, ctx}} -> %>
                    <.live_component
                      module={LoopyardWeb.Live.WorkspaceLive.MessageRowComponent}
                      id={"mr-#{msg[:id] || idx}"}
                      msg={msg}
                      idx={idx}
                      ctx={ctx}
                      agent_id={@agent_id}
                      workspace_id={@workspace_id}
                      host={@host}
                      user_label={@user_label}
                      active?={MapSet.member?(@active_prompt_ids, msg[:id])}
                      detail_level={@detail_level}
                    />
                  <% {:run, items} -> %>
                    <%!-- The response flows directly under its "You" prompt (which
    carries the dated timestamp) — no "Claude" marker. The
    `space-y` gives each step (text, tool call, result) room to
    breathe instead of packing them edge-to-edge; the console
    boxes and file cards especially need the air to read as
    separate acts, not one dense wall. --%>
                    <div class="mt-2">
                      <div class="space-y-4">
                        <.live_component
                          :for={{msg, idx, ctx} <- items}
                          module={LoopyardWeb.Live.WorkspaceLive.MessageRowComponent}
                          id={"mr-#{msg[:id] || idx}"}
                          msg={msg}
                          idx={idx}
                          ctx={ctx}
                          agent_id={@agent_id}
                          workspace_id={@workspace_id}
                          host={@host}
                          user_label={@user_label}
                          active?={MapSet.member?(@active_prompt_ids, msg[:id])}
                          detail_level={@detail_level}
                        />
                      </div>
                    </div>
                <% end %>
              <% end %>
            </section>
            <%!-- Live tail: the agent's in-progress work on ONE continuous rail. A
    single line runs from the Claude icon's CENTER straight down through
    the reasoning and into the live status — one unbroken timeline. The
    icon + "Claude" label show only when this is the top of the response
    (pure thinking); once the section above owns the header, just the line
    continues. --%>
            <div
              :if={
                @streaming_text != "" || (assigns[:streaming_thinking] || "") != "" ||
                  @agent.status in [:backoff, :compacting] ||
                  (@agent.status == :thinking && not awaiting_answer?(@messages) &&
                     not awaiting_approval?(@messages) && not building?(@messages))
              }
              class="-mx-4 md:-mx-6 wide:-mx-4 px-4 md:px-6 chat-live-rail-tail"
            >
              <%!-- The lit violet left rail: this wrapper renders ONLY while the
    turn is live (streaming / thinking / restarting / compacting), so
    the rail marks exactly the content being written right now. It's
    aligned to the column edge — same x as the active prompt band's
    left rail above — so the two read as one continuous "current turn"
    timeline. --%>
              <%!-- `initial` seeds the thinking text ONLY in static renders
    (showcase screenshots — @static?): live, the element is created by
    the same diff that pushes the first delta, so seeding there would
    double that chunk. The hook owns the text in live sessions. --%>
              <.streaming_thinking
                :if={
                  @detail_level != :chat && assigns[:streaming_thinking] != "" &&
                    assigns[:streaming_thinking] != nil
                }
                initial={(assigns[:static?] && @streaming_thinking) || ""}
              />
              <.streaming_bubble :if={@streaming_text != ""} streaming_text={@streaming_text} />
              <.thinking_indicator
                :if={
                  @agent.status == :thinking && @streaming_text == "" &&
                    (assigns[:streaming_thinking] || "") == "" &&
                    not awaiting_answer?(@messages) && not awaiting_approval?(@messages) &&
                    not building?(@messages)
                }
                messages={@messages}
                word={@thinking_word}
              />
              <.live_status
                :if={@agent.status in [:thinking, :backoff, :compacting]}
                messages={@messages}
                word={@thinking_word}
                agent_id={@agent.id}
                mode={live_status_mode(@agent)}
                streaming_text={@streaming_text}
                active_tool={@agent[:active_tool]}
                tool_calls={@agent[:tool_calls_this_turn] || 0}
                tokens={(@agent[:total_input_tokens] || 0) + (@agent[:total_output_tokens] || 0)}
                context_utilization={@agent[:context_utilization] || 0.0}
              />
            </div>
          </div>
        </div>
      </div>
      <%!-- The composer: queue + Reasoning Bar + input, grouped as ONE unit. The
    input lives in its own phx-update="ignore" wrapper (the ChatForm hook
    owns flush/ack/mobile/Enter — do NOT move it inside something LV
    patches). The queue and the always-visible Reasoning Bar sit above it,
    LiveView-updated, so you can keep queuing and watch progress while the
    agent works. --%>
      <%!-- pb-safe: the composer clears the home indicator in a standalone PWA
    while keeping its normal padding in the browser. --%>
      <div class="flex-none pb-safe">
        <div class="w-full wide:max-w-3xl mx-auto px-3 md:px-6">
          <%!-- The queue is ONE card: a single "You" band (one name, one state) with
    every pending line INSIDE it, each line cancelable by its own ✕. Reads
    as one prompt-in-waiting — exactly how the transcript groups a batch —
    never a stack of repeated BRAD/queued headers. When the agent takes
    the turn, the queue drains: these lines become the committed prompt
    band above (dated, highlighted) with the live Working/Stop status
    below — the ✕'s are gone because it's no longer editable. --%>
          <%!-- Desaturated a notch against the committed prompt band
    (violet-100 / #2b2348). Queued lines aren't part of the transcript
    yet — they're waiting on the agent — so they read as the quieter
    sibling of the band they'll become, not as an equal. --%>
          <div
            :if={(@agent[:pending_count] || 0) > 0}
            class="-mx-3 md:-mx-6 wide:-mx-4 wide:mt-2 bg-violet-50 dark:bg-[#241f3a] px-4 md:px-6 pt-3 pb-3"
          >
            <%!-- Identity left, state to the RIGHT — same anatomy as the
      committed prompt band above, so the queue reads as that same
      object in a different state. "Clear all" rides with the state on
      the right; three justify-between children would have centred the
      state instead of right-aligning it. --%>
            <div class="flex items-baseline justify-between gap-3 mb-1.5">
              <span class="inline-flex items-center gap-1.5 text-lead font-semibold uppercase tracking-wide text-violet-600/90 dark:text-violet-300/80 flex-none">
                <.icon name={:user} class="w-3.5 h-3.5 flex-none self-center" /> {@user_label}
              </span>
              <div class="flex items-baseline gap-3 min-w-0">
                <span class="text-lead text-violet-500/70 dark:text-violet-300/50 truncate">
                  Queued
                </span>
                <button
                  :if={(@agent[:pending_count] || 0) > 1}
                  type="button"
                  phx-click="clear_pending"
                  phx-value-id={@agent.id}
                  class="focus-ring flex-none text-body text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-300"
                >
                  Clear all
                </button>
              </div>
            </div>
            <ul class="space-y-1.5">
              <li
                :for={{text, i} <- Enum.with_index(@agent[:pending_messages] || [])}
                class="group/q flex items-start justify-between gap-2"
              >
                <%!-- The text is TEXT. It used to be a full-width button wired to
    edit_pending, which DEQUEUES the message and dumps it into the
    composer — so tapping a queued line to read it silently pulled a
    message the agent was about to run out of the queue and left a wall
    of raw prompt sitting in the input box. On a phone, tapping a block
    of text is how you read it, not how you edit it. Nothing about the
    row said it was a button, because it shouldn't have been one. --%>
                <p class="flex-1 min-w-0 text-lead leading-relaxed text-zinc-800 dark:text-zinc-100 line-clamp-3">
                  {text}
                </p>
                <%!-- Edit is now its OWN control, named and deliberate — the only
    thing allowed to put text in the composer is a human asking for it. --%>
                <button
                  type="button"
                  phx-click="edit_pending"
                  phx-value-id={@agent.id}
                  phx-value-index={i}
                  aria-label="Edit this queued message"
                  title="Edit — pull back into the message box"
                  class="focus-ring tap-target flex-none w-9 h-9 -my-1.5 rounded-sm flex items-center justify-center text-violet-500/50 dark:text-violet-300/40 hover:text-violet-600 dark:hover:text-violet-300 hover:bg-violet-500/10 transition-colors"
                >
                  <.icon name={:pencil} class="w-4 h-4" />
                </button>
                <%!-- Cancel just THIS line — always visible (hover-only was invisible
    on touch). --%>
                <button
                  type="button"
                  phx-click="remove_pending"
                  phx-value-id={@agent.id}
                  phx-value-index={i}
                  aria-label="Cancel this queued message"
                  title="Cancel — remove from the queue"
                  class="focus-ring tap-target flex-none w-9 h-9 -my-1.5 rounded-sm flex items-center justify-center text-violet-500/50 dark:text-violet-300/40 hover:text-red-500 hover:bg-red-500/10 transition-colors"
                >
                  <.icon name={:x_mark} class="w-4 h-4" />
                </button>
              </li>
            </ul>
          </div>
          <%!-- Auto-compaction is house-keeping the user shouldn't have to care about:
    no pre-warning, and only a tiny muted marker WHILE it's actually
    happening (≥92%). It's automatic and lossless (full history is kept),
    so it never needs a sentence or an alarm. --%>
          <div
            :if={(@agent[:context_utilization] || 0.0) >= 0.92}
            class="flex items-center gap-1.5 my-2 text-lead text-zinc-500 dark:text-zinc-400"
          >
            <span class="flex-none">🗜</span>
            <span class="min-w-0">Compacting…</span>
          </div>
          <%!-- The composer IS the input: the whole bottom bar (border-t above)
    reads as one big submission unit — no inner boxed textarea, no big
    filled button. Just the caret and a quiet violet arrow. --%>
          <%!-- OPTIMISTIC SEND ECHO: the instant you hit Enter, the ChatForm hook
             clears the box and shows your text HERE — the exact spot and skin
             of the server queue band — so the message is visible immediately
             even when the LiveView is busy streaming (the ack can lag seconds).
             On ack the server band replaces it seamlessly; on failure the text
             returns to the box. phx-update="ignore": the hook owns it. --%>
          <div
            id="send-echo"
            phx-update="ignore"
            class="hidden -mx-3 md:-mx-6 wide:-mx-4 wide:mt-2 bg-violet-100 dark:bg-[#2b2348] px-4 md:px-6 pt-3 pb-3"
          >
            <div
              data-echo-label
              class="text-body font-semibold uppercase tracking-wide text-violet-600 dark:text-violet-300 mb-1.5"
            >
              Sending…
            </div>
            <div
              data-echo-text
              class="text-lead text-zinc-800 dark:text-zinc-100 whitespace-pre-wrap line-clamp-3"
            >
            </div>
          </div>
        </div>
        <%!-- The composer divider: just ABOVE the message box, BELOW the queued
            card. A DIRECT child of the pane (not the centered column), so it
            spans the full width of the screen/pane. --%>
        <div class="w-full border-t border-zinc-200 dark:border-zinc-700/80 mb-2"></div>
        <div class="w-full wide:max-w-3xl mx-auto px-3 md:px-6">
          <div id="chat-form-wrapper" phx-update="ignore">
            <form
              id="chat-form"
              phx-submit="send_message"
              phx-hook="ChatForm"
              class="flex items-end gap-2"
            >
              <textarea
                name="message"
                id="chat-input"
                rows="1"
                placeholder="Type a message..."
                aria-label="Message"
                autocomplete="off"
                class="focus-ring text-lead flex-1 bg-transparent border-0 rounded-sm px-1 py-2.5
    text-zinc-900 dark:text-zinc-100 placeholder:text-zinc-400 resize-none
    focus:outline-none focus:ring-0"
              ></textarea>
              <button
                type="submit"
                aria-label="Send"
                class="focus-ring flex-none flex items-center justify-center rounded-full w-11 h-11 md:w-10 md:h-10 mb-[5px] md:mb-1 text-violet-600 dark:text-violet-400
    hover:bg-violet-50 dark:hover:bg-violet-500/10 transition-colors"
              >
                <.icon name={:arrow_up} class="w-6 h-6" />
              </button>
            </form>
            <%!-- Why a send failed — the ChatForm hook fills + reveals this so a
    rejected send is never just a silent red flash. --%>
            <p id="send-status" class="hidden mt-1.5 text-lead text-red-500 dark:text-red-400"></p>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # --- Container Panel ---

  def container_panel(%{has_container: false} = assigns) do
    ~H"""
    <div class="flex-1 flex items-center justify-center">
      <p class="text-lead text-zinc-500 dark:text-zinc-400">No container running</p>
    </div>
    """
  end

  def container_panel(assigns) do
    ~H"""
    <div class="flex-1 flex flex-col min-h-0 overflow-y-auto">
      <div class="flex items-center justify-end px-4 py-2 bg-zinc-50 dark:bg-zinc-800/50 border-b border-zinc-200 dark:border-zinc-700/80">
        <button
          phx-click="refresh_container"
          class="text-lead text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-300 transition-colors"
        >
          Refresh
        </button>
      </div>
      <div :if={@env} class="border-b border-zinc-200 dark:border-zinc-700/80">
        <div class="px-4 py-2 bg-zinc-50 dark:bg-zinc-800/50">
          <h3 class="text-lead font-semibold uppercase tracking-wider text-zinc-500">Environment</h3>
        </div>
        <pre class="px-4 py-3 text-lead md:text-[13px] font-mono leading-snug text-zinc-600 dark:text-zinc-400 overflow-x-auto whitespace-pre-wrap max-h-48 overflow-y-auto">{@env}</pre>
      </div>
      <div class="flex-1 flex flex-col min-h-0">
        <div class="flex items-center justify-between px-4 py-2 bg-zinc-50 dark:bg-zinc-800/50 border-b border-zinc-200 dark:border-zinc-700/80">
          <h3 class="text-lead font-semibold uppercase tracking-wider text-zinc-500">Logs</h3>
          <form phx-change="filter_container_service" class="inline">
            <input
              type="text"
              name="service"
              value={@log_service || ""}
              placeholder="Filter service..."
              aria-label="Filter logs by service"
              class="text-lead rounded-sm border border-zinc-300 dark:border-zinc-600 bg-white dark:bg-zinc-800 px-2 py-1 w-28
    focus:outline-none focus:ring-1 focus:ring-violet-500/30"
            />
          </form>
        </div>
        <pre class="flex-1 px-4 py-3 text-lead md:text-[13px] font-mono leading-snug overflow-auto whitespace-pre-wrap bg-zinc-100 dark:bg-zinc-950 text-zinc-800 dark:text-green-400 min-h-[200px]">{@logs}</pre>
      </div>
    </div>
    """
  end
end
