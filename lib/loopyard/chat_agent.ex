defmodule Loopyard.ChatAgent do
  @moduledoc """
  GenServer wrapping a Claude Code SDK session.
  Streams structured messages to viewers via PubSub.
  Unlike the PTY-based Agent, this uses the JSON protocol
  for a proper multiplayer chat experience.
  """

  # Force recompile: 2026-03-26T14:55
  # :temporary — the DynamicSupervisor never auto-restarts. The
  # Loopyard.ChatAgent.RestartController GenServer owns every
  # respawn decision synchronously, which gives us exact quarantine
  # semantics: the Nth crash quarantines before the N+1th can occur.
  # See plans/coordination-hardening.md Move #10.
  use GenServer, restart: :temporary
  require Logger

  alias Loopyard.ChatAgent.{
    Client,
    IdleReaper,
    Initializer,
    Lifecycle,
    MessageLog,
    MessageWindow,
    Persistence,
    Prompt,
    Restart,
    SendGuards,
    SessionManager,
    Summary,
    StreamHandler,
    TurnHelpers
  }

  alias Loopyard.Events

  defstruct [
    :id,
    :name,
    :session,
    :session_opts,
    # Boot opts (tools/prompt/model/container) needed to REBUILD session_opts on
    # a full "reload tools" restart. Runtime-only, NOT persisted — a server
    # restart repopulates it from the resume opts. See Initializer.rebuild_session_opts/1.
    :init_opts,
    :backend,
    :working_dir,
    :bind_mount,
    # Host access is OPT-IN and explicit — NEVER a fallback. `host_access: true`
    # is the sole thing that grants a `bind_mount` (native host tools). Default
    # false → container-only. Persisted so a DELIBERATE opt-in survives resume,
    # while a stray/legacy bind_mount does not (resume keys off this, not
    # bind_mount). See docs/SECURITY.md.
    :host_access,
    :workspace_id,
    # An explicit container this agent's tools run inside, INSTEAD of a
    # workspace-derived work container. Set for the operator agent, which has no
    # workspace but lives in its workstation image. `resolve_container/1` prefers
    # this when present. nil for normal (workspace) agents.
    :container,
    # The workstation identity this agent boots its home/env from (the one you
    # were operating as when it started). Lets us count agents per identity and,
    # later, find who to refresh when that identity's home changes.
    :workstation_identity,
    :started_at,
    :started_by,
    :last_activity_at,
    :service_name,
    :claude_session_id,
    status: :idle,
    messages: [],
    tool_calls: 0,
    errors: 0,
    stream_ref: nil,
    # Pid of the linked stream Task for the in-flight turn. Used (alongside
    # `session`) to tell whether an incoming {:EXIT, pid, _} belongs to the
    # CURRENT turn or to an already-replaced session/task. Runtime-only, not
    # persisted.
    stream_task_pid: nil,
    model: nil,
    total_input_tokens: 0,
    total_output_tokens: 0,
    total_cache_read_tokens: 0,
    total_cost_usd: 0.0,
    active_tool: nil,
    turns: 0,
    # Rate-limit + auth surface. `rate_limit_status` tracks what the
    # last %Event.RateLimitStatus said (:ok | :warning | :rejected).
    # On :rejected we flip the main status to :rate_limited and stash
    # `rate_limit_resets_at_ms` so the UI can render a countdown + we
    # can auto-retry exactly at reset. On auth failure we flip to
    # :auth_expired and stop retrying — there is no automated
    # recovery from bad creds.
    rate_limit_status: :ok,
    rate_limit_resets_at_ms: nil,
    rate_limit_type: nil,
    # Fraction of the cap consumed (0.0–1.0+, >1 once in overage), so the
    # UI/chat can say "~92% of cap" instead of just "limited".
    rate_limit_utilization: nil,
    auth_error: nil,
    # Transient turn-failure auto-retry (529 / overload / execution error).
    # The inbox owns durability, so a turn that fails on an upstream blip is
    # re-issued rather than silently answered-with-an-error. `current_turn_prompt`
    # is the exact text sent to the backend for this turn (so a retry re-issues
    # it verbatim); `turn_retry_count` bounds the attempts; `pending_turn_error`
    # is set by the SessionResult handler and read at stream-done to decide a
    # retry; `failed_prompt` preserves the message for one-tap resend once
    # retries are exhausted.
    current_turn_prompt: nil,
    # :human (typed by a person) | :seed (machine-built resume/continuation
    # prompt). Failure handling differs: a failed human turn gets a chat
    # error; a failed seed turn is EventLog-only (its prompt is regenerable
    # machinery — surfacing it, or worse restoring it anywhere, is noise).
    current_turn_origin: :human,
    turn_retry_count: 0,
    pending_turn_error: nil,
    failed_prompt: nil,
    # OS pid of the Claude CLI subprocess owned by state.session. Tracked
    # via Loopyard.Resources.track/4 so the Janitor kills it on our
    # DOWN — covers the brutal_kill / node crash / :shutdown-timeout
    # cases where `terminate/2` never runs. See plans/agent-sanity.md #12.
    tracked_cli_os_pid: nil,
    # SHA-256 of the system_prompt passed to `append_system_prompt` on
    # start_session. Stored alongside claude_session_id so init_resume
    # can detect when the prompt has changed between boots (CLAUDE.md
    # edit, tool set updated). When it differs,
    # we emit telemetry + an inline marker so the user knows the agent
    # is now operating under different instructions than its earlier
    # turns were generated under. See agent-sanity #19.
    prompt_hash: nil,
    # Idle-reap bookkeeping. On every :idle_check tick (scheduled in
    # init_fresh / init_resume and after every activity), if the agent
    # has been idle longer than `@idle_reap_hours` AND has a captured
    # claude_session_id (so we can come back via `resume:`), we stop
    # the CLI subprocess + clear state.session. The ChatAgent
    # GenServer stays alive with full state; a subsequent
    # :send_message re-spawns the CLI via ensure_session_alive and
    # resumes the exact same conversation with no user-visible loss.
    # RAM freed: ~200MB per reaped CLI. See agent-sanity #20.
    idle_check_timer: nil,
    # Loop detection. A tuple `{tool_hash, consecutive_count}` tracking
    # the last tool call the agent made and how many times in a row
    # it's been the exact same {tool_name, input}. At
    # @tool_loop_threshold the handler appends an inline warning.
    # Cleared on any different tool, user message, or stream_done.
    # See agent-sanity follow-up (answer to "what else?").
    last_tool_call: nil,
    # Tool-call-runaway tracker: how many tool calls (ANY tool + ANY
    # input, distinct from last_tool_call's same-tool repeat gate) the
    # agent has made in the current turn. Many agents legitimately
    # call 5-20 tools to gather context; anything over
    # @turn_tool_limit is almost certainly runaway behavior. Warn
    # once per turn. Reset on stream_done + on user :send_message.
    tool_calls_this_turn: 0,
    tool_runaway_warned: false,
    # FIFO queue of `:send_message` casts that arrived while the agent
    # was busy (:thinking, :backoff, :rate_limited, :auth_expired —
    # any status where a new stream Task can't start). Drained on
    # :stream_done / :stream_error / :stream_timeout / :rate_limit_retry
    # so the user's rapid-fire messages process in order instead of
    # spawning parallel streams against one Claude session (which the
    # SDK's query_queue might serialize but with undefined-to-us
    # interleaving). See agent-sanity #15.
    pending_sends: [],
    # Fraction of the model's context window used by the current turn
    # (0.0–1.0+). Computed from the last %Event.SessionResult{}'s
    # `input_tokens` divided by the model's published window size.
    # When >= 0.85 we append an inline warning so users know to
    # /clear or start a fresh agent before the CLI silently drops
    # earliest turns. See agent-sanity #18.
    context_utilization: 0.0,
    # True after we've warned about high utilization for this
    # stream; cleared on next stream_done so the warning doesn't
    # repeat every turn once the user acknowledges.
    context_warning_sent: false,
    # Accumulates `%Event.TextDelta{}` chunks during a streaming turn.
    # If the stream completes successfully, `%Event.Text{}` arrives and
    # we reset this to "". If the stream is cut short (stream_error,
    # stream_timeout, CLI crash mid-turn), the stream-interrupt handler
    # finalizes whatever text we accumulated as a partial assistant
    # message with a "(truncated — CLI crashed)" marker so users don't
    # lose the partial response after a browser refresh. Transient;
    # NOT included in summary/1 — lives only in the live GenServer.
    # See plans/agent-sanity.md #3.
    in_flight_partial: "",
    # Publish coalescing for streaming deltas. Raw SDK token events arrive
    # 30–60×/s; publishing each one made every viewer's LiveView re-ship and
    # re-patch the whole accumulated text per token, saturating the browser
    # main thread (typing lagged during heavy streams). Instead deltas queue
    # here ({:text | :thinking, chunk}, reversed) and a timer flushes one
    # combined publish per channel every @delta_flush_ms. Dropped (never
    # flushed) on turn reset/interrupt — the finalized Message supersedes.
    # Transient; NOT in summary/1.
    stream_pub_buffer: [],
    stream_pub_timer: nil,
    # Unexpected CLI deaths since the last CLEAN turn completion (or last
    # fresh/compacted session). This is the compact-instead-of-resume breaker
    # signal: a session whose harness keeps dying mid-conversation has almost
    # certainly outgrown the work container's memory cap (ACP reports no token
    # usage, so the utilization-based compaction can't see it — see
    # IMPROVEMENTS #20), and `resume:`-ing it just reloads the bloat that
    # killed it. At @compact_after_midturn_crashes the recovery paths route
    # through {:auto_restart_context, nil} (summarize → fresh session)
    # instead of resuming. NOT reset by reset_turn_state — this is session
    # health, not turn state. Incremented via SessionManager.note_cli_death/1.
    midturn_crashes: 0
  ]

  @ets_table :chat_agents

  # Hard cap on a single :send_message cast payload. Claude's own
  # limit is much higher (context-window-bound) but any single 1MB
  # input is almost certainly a paste mistake, a runaway automation,
  # or a tool feeding back its own output. Rejecting here protects:
  # the agent mailbox, PubSub broadcast fanout to every viewer, and
  # the Claude API bill. Configurable via Application env for tests
  # that want to exercise the reject path with smaller inputs.
  @max_message_bytes Application.compile_env(:loopyard, :max_message_bytes, 1_048_576)

  # Compact-instead-of-resume breaker: after this many unexpected CLI deaths
  # since the last clean turn (see midturn_crashes on the struct), recovery
  # compacts (summarize → fresh session) rather than resuming the session
  # that keeps killing its harness.
  #
  # ONE, not two. `session/load` resume of a large session is the crash source
  # (claude-agent-acp #338 / discussion #871: full-JSONL replay dies), while a
  # fresh `session/new` is reliable. Giving a just-crashed session a SECOND
  # resume just crashes again — and because a clean turn resets this counter,
  # an intermittently-crashing resume never reached the old threshold of 2, so
  # the user hit failed turn after failed turn forever. Tripping on the FIRST
  # crash means: crash → immediately drop to a fresh, summarized session (the
  # compaction path re-sends the user's message), so the turn auto-completes
  # instead of failing. Loopyard keeps the full chat log either way; only the
  # HARNESS's in-context history compacts to a summary.
  @compact_after_midturn_crashes 1

  @doc """
  True when this agent's session has died mid-conversation enough times that
  resuming it again is just reloading the bloat that killed it — recovery
  paths (`:restart_session`, `ensure_alive`, stream-error restart) consult
  this and route to compaction instead. Map.get: agents live through hot
  reloads holding pre-upgrade structs.
  """
  def compaction_breaker_tripped?(state),
    do: Map.get(state, :midturn_crashes, 0) >= @compact_after_midturn_crashes

  # Stream STALL budget: how long a turn's stream may be SILENT (no events at
  # all) before the CLI is presumed wedged and rebooted. This is deliberately
  # not a turn-duration cap — a busy long-running task streams tool calls and
  # text the whole way through and must never be killed for taking its time.
  @stream_stall_ms 600_000

  # Grace before the idle sweep self-heals a ghost :thinking turn (dead session).
  # Long enough that a legitimate session-swap window during a restart is never
  # mistaken for a wedge; short enough that a real strand recovers in well under
  # the old "wait for the 10-min stall watchdog (that never fired)" failure.
  @ghost_sweep_grace_ms 45_000

  # --- Public API ---
  #
  # The thin client wrappers (call/cast via the Registry, ETS read
  # fallbacks) live in Loopyard.ChatAgent.Client; every public name is
  # re-exposed here so external callers keep saying ChatAgent.foo.

  defdelegate start_link(opts), to: Client
  defdelegate send_message(id, text), to: Client

  @doc "Durability-confirmed send for the interactive UI (see `Client.enqueue_message/2`)."
  defdelegate enqueue_message(id, text), to: Client

  defdelegate get_state(id), to: Client
  defdelegate stop_agent(id), to: Client
  defdelegate rename(id, new_name), to: Client

  @doc "Get a specific message by ID from the agent's ETS state."
  defdelegate get_message(agent_id, msg_id), to: Client

  @doc "Get a page of messages — `{messages_slice, total_count}` (see MessageWindow)."
  defdelegate get_messages(agent_id, opts \\ []), to: Client

  @doc "Append a message from outside the GenServer (see MessageWindow.append_message_ets/2)."
  defdelegate append_message_ets(agent_id, msg), to: MessageWindow

  @doc "Update a message by ID; GenServer if alive, ETS fallback (see MessageWindow.update_message/3)."
  defdelegate update_message(agent_id, msg_id, update_fn), to: MessageWindow

  @doc "Restart the CLI session, keeping the agent + messages (see `Client.restart_session/2` for reasons)."
  defdelegate restart_session(id, reason \\ :user), to: Client

  @doc "Switch the agent's model (Usage-panel Model row); see ChatAgent.ModelControl."
  defdelegate set_model(id, model_id), to: Client

  @doc "Start a stopped/crashed agent — starts a new GenServer and resumes from saved state"
  defdelegate start_agent(id), to: Lifecycle

  @doc "Remove a stopped/crashed agent — transitions to :destroying, cleans up Docker, then removes from sidebar"
  defdelegate remove_agent(id), to: Lifecycle

  @doc "Register an agent as booting in ETS so all viewers can see it"
  defdelegate register_booting(id, name, working_dir, opts \\ []), to: Client

  @doc "Update boot status in ETS and broadcast to all viewers"
  defdelegate update_boot_status(id, status_text), to: Lifecycle

  @doc "Mark a booting agent as failed and remove it"
  defdelegate boot_failed(id, reason), to: Lifecycle

  @doc "List every agent's current summary, freshening live ones from their GenServer."
  defdelegate list_agents(), to: Lifecycle

  @doc "Every agent's summary from ETS only — no GenServer calls (mount-safe)."
  defdelegate list_agent_summaries(), to: Lifecycle

  @doc "Summaries for ONE workspace, freshening live ones — scoped ETS scan (mount-path query)."
  defdelegate list_agents_for_workspace(workspace_id), to: Lifecycle

  @doc "Cheap yes/no: any agent for this workspace already in ETS? No GenServer calls."
  defdelegate workspace_loaded?(workspace_id), to: Lifecycle

  defdelegate subscribe(), to: Client
  defdelegate subscribe(agent_id), to: Client
  defdelegate unsubscribe(agent_id), to: Client

  # --- GenServer init and session startup ---
  #
  # init/1 dispatches to init_fresh (brand-new agent) or init_resume
  # (log-replay case). Both end up calling start_session/3 which
  # builds the Claude SDK session options and kicks off the CLI
  # subprocess via the configured backend. See docs/ARCHITECTURE.md
  # for the full boot flow.
  #
  # --- Callbacks ---

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    id = Keyword.fetch!(opts, :id)

    case Initializer.build_state(id, opts) do
      {:ok, state, :prompt_drift} ->
        # Agent-sanity #19 — prompt drift marker. Announce the change in
        # the conversation so the user isn't mystified if the agent
        # behaves differently than it did pre-boot.
        drift_msg = %{
          role: :system,
          content:
            "⚠ System prompt changed since this agent's last boot. Earlier turns in this " <>
              "conversation were generated under the prior instructions; new turns will " <>
              "follow the updated ones — behavior may differ.",
          timestamp: DateTime.utc_now()
        }

        {state, drift_msg} = append_message(state, drift_msg)
        Persistence.persist_message(state, drift_msg)

        Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{
          agent_id: id,
          msg: drift_msg
        })

        # Re-persist summary after appending the drift message
        :ets.insert(@ets_table, {id, summary(state)})
        {:ok, state}

      {:ok, state} ->
        {:ok, state}

      {:stop, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  # --- Message flow ---
  #
  # send_message/stop/restart_session/rename are the hot path for user
  # (and agent→agent, now gated) interaction. Appending messages,
  # broadcasting to subscribers, and journaling to the ETF log all
  # happen here.

  # Defensive: non-binary / nil payloads are callers with bugs (UI
  # handler returning nil by accident, test harness passing the
  # wrong shape). Reject with a clear error in the conversation
  # instead of crashing the GenServer with a FunctionClauseError or
  # byte_size(nil) ArgumentError.
  def handle_cast({:send_message, text}, state) when not is_binary(text) do
    :telemetry.execute(
      [:loopyard, :agent, :message_rejected],
      %{count: 1},
      %{agent_id: state.id, reason: :non_binary}
    )

    require Logger

    Logger.warning(
      "[ChatAgent] #{state.id} received non-binary send_message: #{inspect(text, limit: 100)}. " <>
        "Rejected. The sender has a bug."
    )

    {:noreply, state}
  end

  def handle_cast({:send_message, text}, state)
      when is_binary(text) and byte_size(text) > @max_message_bytes do
    # Reject oversized input before it hits any stream. A 50MB paste
    # would otherwise: blow up ETS term size, trigger huge PubSub
    # broadcasts to every viewer, burn a turn at maximum Claude cost,
    # and potentially crash the mailbox with message-too-big. Much
    # better to refuse cleanly.
    :telemetry.execute(
      [:loopyard, :agent, :message_rejected],
      %{bytes: byte_size(text)},
      %{agent_id: state.id, reason: :oversized}
    )

    reject_msg = %{
      role: :error,
      content:
        "Message rejected — #{byte_size(text)} bytes exceeds the " <>
          "#{@max_message_bytes}-byte limit. Paste to a file and reference it " <>
          "instead, or break the content into smaller chunks.",
      timestamp: DateTime.utc_now()
    }

    {state, reject_msg} = append_message(state, reject_msg)

    Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{
      agent_id: state.id,
      msg: reject_msg
    })

    {:noreply, state}
  end

  def handle_cast({:send_message, text}, state) do
    :telemetry.execute([:loopyard, :agent, :message], %{}, %{agent_id: state.id, role: :user})

    cond do
      # The agent is BLOCKED on an `ask_user` question (its turn is
      # parked inside the tool call, waiting for the card to be
      # answered). A free-text chat message here means "use this
      # instead of the buttons" — deliver it as the answer so the turn
      # unblocks with the user's actual intent. Without this, the
      # message queues behind a turn that can't finish until the
      # question is answered → deadlock (the agent shows "Asking…"
      # forever while the user's reply sits "Queued"). Record the
      # message as a normal user turn-input so it's visible, then
      # resolve the question.
      Loopyard.Harness.Questions.pending_for_agent?(state.id) and state.status != :idle ->
        user_msg = %{role: :user, content: text, timestamp: DateTime.utc_now()}
        {state, user_msg} = append_message(state, user_msg)
        Persistence.persist_message(state, user_msg)

        Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{
          agent_id: state.id,
          msg: user_msg
        })

        Loopyard.Harness.Questions.answer_with_text(state.id, text)
        {:noreply, state}

      # ORPHANED question: a question reports "pending" but the agent is :idle.
      # A genuinely-live ask_user parks the turn INSIDE the tool call, so the
      # agent is never idle while really waiting. Idle + pending means the broker
      # Task leaked — the harness abandoned the elicitation on its own (shorter)
      # timeout while our ask/2 kept blocking for its full 10-min window. Routing
      # the reply to answer_with_text would hand it to a consumer that's already
      # gone → the message is silently eaten and the agent never responds (the
      # "I typed a reply and the operator went dead" stall). Cancel the leaked
      # question and treat the message as a fresh prompt — start a real turn.
      Loopyard.Harness.Questions.pending_for_agent?(state.id) ->
        Loopyard.Harness.Questions.cancel_for_agent(state.id)
        send_message_normal(state, text)

      # Ghost :thinking — the status says a turn is in flight, but there's
      # NO live stream and NO live session. A real turn always carries a
      # stream_ref backed by a live session (set atomically in start_turn);
      # this shape only happens when a turn died WITHOUT running a
      # reset-to-idle path (e.g. a session crash during a reconnect). If we
      # let it fall into the busy-enqueue clause below, the message parks
      # behind a turn that can never complete or drain → the agent silently
      # wedges and every send vanishes. Self-heal to idle and send for real.
      TurnHelpers.ghost_thinking?(state) ->
        Logger.warning(
          "[#{state.id}] recovering ghost :thinking (no stream, no live session) on send"
        )

        :telemetry.execute([:loopyard, :agent, :ghost_turn_recovered], %{}, %{agent_id: state.id})
        send_message_normal(TurnHelpers.reset_ghost_turn(state), text)

      # Agent-sanity #15. If a turn is already in flight (:thinking)
      # or pending restart (:backoff), starting a second stream Task
      # against the same Claude session risks interleaved events or
      # an error from the SDK's query_queue. Record the message so
      # the user sees it didn't vanish, then enqueue for
      # post-turn drain. The turn-completion handlers
      # (:stream_done / :stream_error / :stream_timeout) pop the
      # queue and resume sends in order.
      state.status in [:thinking, :backoff, :rate_limited] ->
        # The agent holds the turn (actively streaming, restarting, OR waiting out
        # a rate limit — all "busy" from the INBOX's view). Rate-limiting is a
        # turn-EXECUTION concern; it must not block the inbox. So park the message
        # in the queue (shown in the queue panel) instead of slapping it into the
        # chat stream — it enters the history only when actually sent on drain.
        state =
          case SendGuards.park_send(state, text) do
            {:ok, state} -> state
            :full -> SendGuards.queue_full_note(state)
          end

        # Refresh the ETS summary so the live queue panel updates.
        :ets.insert(@ets_table, {state.id, summary(state)})

        Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{
          id: state.id,
          status: state.status
        })

        {:noreply, state}

      is_binary(state.auth_error) or state.status == :auth_expired ->
        # CONFIRMED auth outage (auth_error persists until a turn proves the
        # token — status alone flaps through self-heal restarts). A user's
        # send ALWAYS gets the answer in chat, every time: their message is
        # queued (the queue band shows it; it delivers itself after re-auth),
        # and the chat says exactly what's blocking + the one link to fix it.
        state =
          case SendGuards.park_send(state, text) do
            {:ok, state} -> state
            :full -> SendGuards.queue_full_note(state)
          end

        # The pending auth-fix CARD is the chat's answer; make sure one exists
        # (it normally does — the outage announcement posts it), but never
        # stack duplicates per send.
        state = SendGuards.ensure_auth_fix_card(state)

        :ets.insert(@ets_table, {state.id, summary(state)})

        Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{
          id: state.id,
          status: state.status
        })

        {:noreply, state}

      true ->
        send_message_normal(state, text)
    end
  end

  @impl true
  def handle_cast(:stop, state) do
    # If the agent was mid-turn with streamed text accumulated but
    # no Event.Text yet, finalize it as a truncated partial so the
    # user doesn't lose their half-answer when they hit Stop. Same
    # mechanism as stream_error / stream_timeout uses.
    state = StreamHandler.finalize_partial_on_stream_interrupt(state, state.id, :stopped_by_user)

    if state.session do
      SessionManager.stop_backend(state.session, state.backend)
    end

    # Null session so terminate/2's second backend.stop is a no-op —
    # we've already spent our 3s budget here; no need to spend another
    # during terminate.
    stopped = %{state | status: :stopped, session: nil, active_tool: nil}

    # Drop queued pending_sends — user chose to stop; they can
    # resend what matters. Log the count so ops can see if stops
    # are habitually discarding user input (would suggest a UX issue).
    if state.pending_sends != [] do
      Loopyard.EventLog.info(
        "agent:#{state.name}",
        "Stop dropped #{length(state.pending_sends)} queued message(s)"
      )
    end

    stopped = %{stopped | pending_sends: []}

    :ets.insert(@ets_table, {state.id, summary(stopped)})
    Events.ChatAgent.publish(%Events.ChatAgent.Stopped{summary: summary(stopped)})
    {:stop, :normal, stopped}
  end

  @impl true
  def handle_cast({:set_model, model_id}, state) do
    {:noreply, Loopyard.ChatAgent.ModelControl.switch(state, model_id)}
  end

  @impl true
  # Internal recovery paths cast the bare atom — they ARE crash recoveries.
  def handle_cast(:restart_session, state), do: handle_cast({:restart_session, :recovery}, state)

  def handle_cast({:restart_session, reason}, state) do
    # Breaker gate: a session whose harness keeps dying mid-conversation has
    # outgrown its memory — resuming it re-feeds the harness the exact history
    # that OOM-killed it, forever. Compact instead: summarize → fresh session
    # (Loopyard keeps the full chat log either way). See midturn_crashes.
    if compaction_breaker_tripped?(state) and state.messages != [] do
      # Harnesses are disposable and the recycle WORKS — so it's silent
      # (EventLog only). The chat speaks only when recovery fails or drags;
      # the sidebar's harness-status shows the in-between.
      Loopyard.EventLog.info("agent:#{state.name}", "recycled harness (context carried over)")

      # Auto-complete the turn the crash interrupted: hand the compaction path
      # the UNANSWERED user message (nil once it's answered, or once we've
      # compacted too many times — a fresh session that ALSO keeps crashing must
      # not loop). So a mid-turn crash becomes: compact → fresh session → the
      # user's question re-runs and answers itself, no "tap Send" needed.
      handle_cast(
        {:auto_restart_context, Restart.pending_user_prompt(state)},
        Map.put(state, :midturn_crashes, 0)
      )
    else
      Restart.restart_session_now(state, reason)
    end
  end

  # Feed a continuation prompt to a freshly-restarted/compacted CLI WITHOUT
  # recording it as a human turn. The user never typed this — it's the
  # crash/compaction resume summary that gets the model going again, so it must
  # never appear as a "YOU" message. The visible artifact is the subtle ":system"
  # recovery note appended by the caller. Best-effort: only start a turn if the
  # agent is idle with a live session; if it's busy (already continuing) or the
  # session is dead (restart flow owns it), drop the nudge — NEVER queue it, since
  # the drain path would resurface it as a fake user turn.
  @impl true
  def handle_cast({:resume_prompt, text}, state) when is_binary(text) do
    state = SessionManager.ensure_alive(state)

    if state.status == :idle and state.backend.session_alive?(state.session) do
      start_turn(%{state | current_turn_origin: :seed}, text)
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:append_external_message, msg}, state) do
    {state, msg} = append_message(state, msg)
    :ets.insert(@ets_table, {state.id, summary(state)})
    Persistence.persist_message(state, msg)

    Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{
      agent_id: state.id,
      msg: msg
    })

    # Auto-continue: if agent is idle and receives an external system message,
    # prompt it to evaluate and continue. The agent decides if work is done.
    if state.status == :idle && msg.role == :system do
      GenServer.cast(self(), {:send_message, "Continue."})
    end

    {:noreply, state}
  end

  # Card-patch convergence: merge the broker's card-state changes into OUR
  # state, then retire the patch record (unless a newer patch superseded it).
  # From here on, plain summary writes carry the change natively.
  @impl true
  def handle_cast({:card_patch, msg_id, changes}, state) do
    messages =
      Enum.map(state.messages, fn msg ->
        if msg[:id] == msg_id, do: Map.merge(msg, changes), else: msg
      end)

    state = %{state | messages: messages}

    case :ets.lookup(:card_patches, {state.id, msg_id}) do
      [{_key, %{card_v: v}}] when v <= changes.card_v ->
        :ets.delete(:card_patches, {state.id, msg_id})

      _ ->
        :ok
    end

    # DURABLY persist the card change (issue #77). Answering a
    # question/approval/secret arrives here, and this path used to update
    # ETS + memory only — so the answer vanished on restart and the card
    # came back :pending, re-asking a decision you already made. `card_v` is
    # a transient UI convergence token, not message state; drop it from what
    # we log. Replay applies {:msg_update, …} by merging (agent_log.ex), so
    # persisting the change is the whole fix — no separate reconciliation.
    Persistence.persist_message_update(state, msg_id, Map.delete(changes, :card_v))

    :ets.insert(@ets_table, {state.id, summary(state)})
    {:noreply, state}
  end

  @impl true
  def handle_cast({:update_message, msg_id, update_fn}, state) do
    # Guard update_fn against raising. A bad caller (or a tool that
    # returned a map the update_fn wasn't written to handle) shouldn't
    # crash the agent — this is just a message-annotation path, not
    # core state. On raise: log, emit telemetry, no-op.
    old_msg = Enum.find(state.messages, &(&1[:id] == msg_id))

    messages =
      try do
        Enum.map(state.messages, fn msg ->
          if msg[:id] == msg_id, do: update_fn.(msg), else: msg
        end)
      rescue
        e ->
          :telemetry.execute(
            [:loopyard, :agent, :update_message_failed],
            %{count: 1},
            %{agent_id: state.id, msg_id: msg_id, reason: Exception.message(e)}
          )

          require Logger

          Logger.warning(
            "[ChatAgent] #{state.id} update_message for #{msg_id} raised: " <>
              Exception.message(e) <> ". Message unchanged."
          )

          state.messages
      end

    state = %{state | messages: messages}
    :ets.insert(@ets_table, {state.id, summary(state)})

    # Persist the changes (diff between old and new)
    new_msg = Enum.find(state.messages, &(&1[:id] == msg_id))

    if old_msg && new_msg && new_msg != old_msg do
      changes = Map.drop(new_msg, [:id])
      Persistence.persist_message_update(state, msg_id, changes)

      # Broadcast the in-place change so every connected viewer patches the
      # message live. Without this, a question card flipping :pending →
      # :answered only reached ETS + the log — the click gave no visual
      # feedback until a full reload.
      Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.MessageUpdated{
        agent_id: state.id,
        msg: new_msg
      })
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:rename, new_name}, state) do
    state = %{state | name: new_name}
    :ets.insert(@ets_table, {state.id, summary(state)})
    Persistence.persist_agent(state, &summary/1)
    Events.ChatAgent.publish(%Events.ChatAgent.Renamed{id: state.id, name: new_name})
    {:noreply, state}
  end

  # Auto-restart when context is exhausted. Restart the CLI session,
  # send the resume summary, then re-send the user's last message.
  def handle_cast({:auto_restart_context, last_user_text}, state) do
    id = state.id

    # Surface "Compacting" on the live bar BEFORE the (blocking) session swap — the
    # GenServer is about to block on stop+start, but this broadcast reaches the LV
    # first, so the user sees the harness doing maintenance (not the model thinking)
    # for the duration of the swap.
    state = %{state | status: :compacting}
    :ets.insert(@ets_table, {id, summary(state)})
    Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: id, status: :compacting})

    # Stop old session
    if state.session do
      task = Task.async(fn -> state.backend.stop(state.session) end)
      Task.yield(task, 3_000) || Task.shutdown(task, :brutal_kill)
    end

    # Start a GENUINELY fresh session — clear claude_session_id so start_opts
    # does NOT pass `resume:`. Resuming would reload the full (overflowing) history
    # and defeat the whole point: this path compacts by handing a FRESH session a
    # SUMMARY (ResumeMessage), so the model's context resets while Loopyard keeps
    # the full chat log. (The old code resumed → summary-into-full-session → a
    # no-op that let a 48h session grow to 6× the window.)
    fresh = %{state | claude_session_id: nil}

    case state.backend.start_session(SessionManager.start_opts(fresh)) do
      {:ok, new_session} ->
        # Track the NEW CLI's OS pid — like every other spawn site — so the
        # Janitor SIGKILLs the live process (not the old, stopped one) on DOWN.
        state =
          SessionManager.track_os_pid(%{
            state
            | session: new_session,
              claude_session_id: nil,
              status: :idle,
              context_utilization: 0.0,
              context_warning_sent: false
          })

        # Fresh session → the harness's memory baseline resets with it; the
        # compact-instead-of-resume breaker starts over.
        state = Map.put(state, :midturn_crashes, 0)

        # Send the resume summary as a SILENT continuation (the user never typed
        # it — it's the compaction summary), not a visible :user turn.
        resume = Loopyard.ChatAgent.ResumeMessage.build(state.messages)
        if resume, do: GenServer.cast(self(), {:resume_prompt, resume})

        # Re-send the user's last message so the agent acts on it
        if last_user_text && last_user_text != "" do
          GenServer.cast(self(), {:send_message, last_user_text})
        end

        :ets.insert(@ets_table, {id, summary(state)})
        Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: id, status: :idle})
        {:noreply, state}

      {:error, reason} ->
        err = %{
          role: :error,
          content:
            "Context compaction couldn't restart the harness (#{inspect(reason)}). " <>
              "WHY: the old session was stopped to compact context, but spawning the fresh one failed. " <>
              "CONSEQUENCE: this turn didn't run; your conversation is preserved. " <>
              "ACTION: send another message — the agent will spawn a new CLI and resume. " <>
              "If it keeps failing, click Restart or check /system/events.",
          timestamp: DateTime.utc_now()
        }

        {state, err} = append_message(state, err)

        # CRITICAL: reset out of :compacting (which isn't even a real resting
        # state) and drop the stopped session, so the next send re-spawns a CLI
        # instead of the UI showing "Compacting" forever. Persist both the
        # status and the error message so a refresh doesn't lose them.
        state = %{state | status: :idle, session: nil, active_tool: nil}

        :ets.insert(@ets_table, {id, summary(state)})
        Persistence.persist_message(state, err)
        Persistence.persist_agent(state, &summary/1)
        Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{agent_id: id, msg: err})
        Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: id, status: :idle})
        {:noreply, state}
    end
  end

  def handle_cast(:interrupt, %{status: :thinking} = state) do
    # Warm interrupt (the turn machine's :cancel_turn effect): tell the backend
    # to stop generating but keep the session ALIVE — no kill, no log-replay (vs.
    # :stop). Preserve the half-answer and invalidate the stream so late events
    # from the interrupted turn are dropped. The QUEUE IS NOT TOUCHED: the
    # interrupt makes the turn finish, so the queue then sends — exactly what the
    # queue panel promises ("sends when the agent finishes"). Use Clear all to
    # discard it instead.
    #
    # But the warm interrupt can WEDGE: the SDK writes to the CLI's stdin and, if
    # the subprocess is hung (pipe full), the call blocks and then the SDK's own
    # session self-crashes at 5s. So we run cancel_turn under a short deadline; if
    # it doesn't ack, the CLI is wedged and we hard-restart (kill + resume),
    # preempting that crash. Fast when healthy, reliable when wedged, no work lost.
    warm_ok? = TurnHelpers.warm_interrupt(state)

    state = StreamHandler.finalize_partial_on_stream_interrupt(state, state.id, :stopped_by_user)

    state = %{
      state
      | status: :idle,
        stream_ref: nil,
        active_tool: nil,
        in_flight_partial: "",
        tool_calls_this_turn: 0,
        tool_runaway_warned: false,
        last_tool_call: nil,
        context_warning_sent: false,
        # Cancel any scheduled transient-failure retry (the counter guard in
        # {:retry_turn_now} mismatches once this is reset).
        turn_retry_count: 0,
        pending_turn_error: nil,
        current_turn_prompt: nil,
        current_turn_origin: :human
    }

    cond do
      not warm_ok? ->
        # CLI was wedged — the warm interrupt didn't land. Hard-restart (kill +
        # resume) clears the wedge and preempts the SDK's 5s self-crash. The
        # restart path drains the pending queue itself, so don't also drain here.
        :ets.insert(@ets_table, {state.id, summary(state)})
        Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: state.id, status: :idle})
        GenServer.cast(self(), :restart_session)
        {:noreply, state}

      state.pending_sends == [] ->
        :ets.insert(@ets_table, {state.id, summary(state)})
        Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: state.id, status: :idle})
        {:noreply, state}

      true ->
        # The agent just "finished" — drain the parked queue as the next turn.
        :ets.insert(@ets_table, {state.id, summary(%{state | pending_sends: []})})
        send_batch(%{state | pending_sends: []}, state.pending_sends)
    end
  end

  # Not mid-turn — "Stop" while idle means put the agent to sleep (hard stop).
  def handle_cast(:interrupt, state), do: handle_cast(:stop, state)

  def handle_cast(:clear_pending, state) do
    if state.pending_sends == [] do
      {:noreply, state}
    else
      {:noreply, set_pending(state, [])}
    end
  end

  def handle_cast({:remove_pending, index}, state) do
    {:noreply, set_pending(state, List.delete_at(state.pending_sends, index))}
  end

  def handle_cast({:update_pending, index, old_text, new_text}, state) do
    updated = SendGuards.update_pending(state.pending_sends, index, old_text, new_text)
    {:noreply, set_pending(state, updated)}
  end

  # Catchall for unknown casts. Without this, any bogus cast would
  # crash the GenServer (FunctionClauseError propagates from a
  # non-matching handle_cast/2). audit-2 already closed this gap for
  # handle_info; this closes it for handle_cast. Emits the same
  # `:unknown_message` telemetry so ops visibility is consistent.
  def handle_cast(msg, state) do
    Logger.warning("[ChatAgent] #{state.id} unhandled cast: #{inspect(msg, limit: 200)}")

    :telemetry.execute(
      [:loopyard, :actor, :unknown_message],
      %{count: 1},
      %{actor: __MODULE__, agent_id: state.id, kind: :cast, msg: inspect(msg, limit: 200)}
    )

    {:noreply, state}
  end

  # restart_note/pending_user_prompt/compaction_looping?/restart_session_now —
  # extracted to Loopyard.ChatAgent.Restart.

  # Replace the pending queue + push the fresh summary to the live queue panel.
  defp set_pending(state, pending) do
    state = %{state | pending_sends: pending}
    :ets.insert(@ets_table, {state.id, summary(state)})
    Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: state.id, status: state.status})
    state
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, summary(state), state}
  end

  # Synchronous confirm for enqueue_message/2. The reply is the durability
  # signal the UI waits on before clearing the input — so it must come back
  # FAST and truthfully. Two regimes:
  #
  # - Session alive (the overwhelmingly common case): run the exact cast logic
  #   inline — append + persist + start the turn — milliseconds — reply :ok.
  # - Session DEAD: do NOT revive it inside the ack window (a resumed ACP
  #   session can take 45s+ to load — the caller's 15s timeout fired first,
  #   reporting "unavailable" for a send that would eventually land, and every
  #   retry stacked another synchronous revival). Instead: QUEUE the text
  #   (pending_sends — drained FIFO when the session comes up), kick the
  #   existing async :restart_session recovery, and reply :ok immediately.
  #   The inbox owns durability; the harness owns turn execution.
  def handle_call({:send_message, text}, _from, state) do
    cond do
      # Busy statuses: the text is heading to pending_sends — a pure state
      # append + broadcast. Do NOT put a harness liveness probe in front of
      # it: ACP's session_alive? round-trips a real JSON-RPC ping through the
      # in-container adapter (up to 2s), and mid-turn that adapter is the
      # BUSIEST it ever gets — the user felt every send take forever when
      # "queued" should be instant. Liveness only matters when we're about to
      # START a turn, and these statuses never do.
      state.status in [:thinking, :backoff, :compacting, :rate_limited, :auth_expired] ->
        {:noreply, new_state} = handle_cast({:send_message, text}, state)
        {:reply, :ok, new_state}

      session_alive_quick?(state) ->
        {:noreply, new_state} = handle_cast({:send_message, text}, state)
        {:reply, :ok, new_state}

      true ->
        case SendGuards.park_send(state, text) do
          {:ok, state} ->
            state = %{state | status: :booting}
            :ets.insert(@ets_table, {state.id, summary(state)})

            Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{
              id: state.id,
              status: :booting
            })

            GenServer.cast(self(), :restart_session)
            {:reply, :ok, state}

          :full ->
            {:reply, {:error, :queue_full}, state}
        end
    end
  end

  # Catchall for unknown calls. Returns an error reply instead of
  # crashing — callers get `{:error, :unknown_call}` they can handle,
  # not a noproc/timeout. Same telemetry as handle_info / handle_cast
  # catchalls.
  def handle_call(msg, _from, state) do
    Logger.warning("[ChatAgent] #{state.id} unhandled call: #{inspect(msg, limit: 200)}")

    :telemetry.execute(
      [:loopyard, :actor, :unknown_message],
      %{count: 1},
      %{actor: __MODULE__, agent_id: state.id, kind: :call, msg: inspect(msg, limit: 200)}
    )

    {:reply, {:error, :unknown_call}, state}
  end

  # Bounded liveness check for the send-ack fast path: nil session or a
  # backend probe that errors/exits reads as dead. ACP's session_alive? is a
  # real ping with its own short timeout; never let a probe blow up the ack.
  defp session_alive_quick?(%{session: nil}), do: false

  defp session_alive_quick?(state) do
    state.backend.session_alive?(state.session)
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  @impl true
  # --- Stream event handling ---
  #
  # The Claude SDK streams events (:stream_event, :stream_done,
  # :stream_timeout, :stream_error) as the CLI produces output. These
  # clauses maintain the agent's in-flight message, broadcast chunks
  # to viewers via PubSub, and transition the agent's status when a
  # turn completes or fails.

  # Ref-tagged stream event. The `stream_ref` identifies which stream
  # produced this event — when the session is replaced mid-turn, the
  # old Task may still have events queued; those must not mutate the
  # new state. Events with a ref != state.stream_ref are dropped. See
  # agent-sanity #16.
  def handle_info({:stream_event, id, ref, event}, %{id: id, stream_ref: ref} = state) do
    # Feed the stall watchdog: the stream timeout fires only after a window of
    # SILENCE, so a long-running turn that's actively producing events is never
    # rebooted mid-work (that killed legitimately busy harnesses — "context
    # canceled" mid-task). Map.put: hot-reload tolerance for old structs.
    state = Map.put(state, :last_stream_event_at, System.monotonic_time(:millisecond))
    {:noreply, StreamHandler.process_event(event, state)}
  end

  # Coalesced-delta flush tick: publish whatever streaming chunks queued up
  # since the last tick (see stream_pub_buffer on the struct). Empty-buffer
  # firings (drop already happened) are a no-op inside the flush.
  def handle_info(:flush_stream_deltas, state) do
    {:noreply, StreamHandler.flush_stream_deltas(state)}
  end

  # Stale stream event — ref doesn't match the current stream. The Task
  # that emitted this belongs to a previous session that was replaced
  # (CLI crash, user restart, retry). Drop it; applying to current state
  # would corrupt the next turn's messages/tokens.
  def handle_info({:stream_event, _id, _ref, _event}, state) do
    :telemetry.execute(
      [:loopyard, :agent, :stale_stream_event],
      %{count: 1},
      %{agent_id: state.id}
    )

    {:noreply, state}
  end

  @impl true
  def handle_info({:stream_done, id, ref}, %{id: id, stream_ref: ref} = state) do
    state = IdleReaper.schedule(state)

    case StreamHandler.on_stream_done(state) do
      {:auto_restart_context, last_user_text, state} ->
        GenServer.cast(self(), {:auto_restart_context, last_user_text})
        {:noreply, state}

      {:retry_turn, prompt, state} ->
        # Opt-in auto-retry. Re-issue after backoff, tagged with the attempt
        # count so a Stop / new message cancels it on arrival.
        delay = Loopyard.Retry.backoff_ms(state.turn_retry_count, {:exponential, 2_000})
        Process.send_after(self(), {:retry_turn_now, id, prompt, state.turn_retry_count}, delay)
        {:noreply, state}

      {:drain, list, state} ->
        send_batch(state, list)

      {:noreply, state} ->
        {:noreply, state}
    end
  end

  # Fire a scheduled transient-failure retry — but only if still valid: same
  # attempt number (a new turn or Stop resets it) and still thinking.
  @impl true
  def handle_info(
        {:retry_turn_now, id, prompt, attempt},
        %{id: id, status: :thinking, turn_retry_count: attempt} = state
      ) do
    start_turn(state, prompt)
  end

  def handle_info({:retry_turn_now, _id, _prompt, _attempt}, state), do: {:noreply, state}

  # Stale stream_done — belongs to a replaced stream, ignore.
  def handle_info({:stream_done, _id, _ref}, state), do: {:noreply, state}

  @impl true
  def handle_info(
        {:stream_timeout, id, ref},
        %{id: id, status: :thinking, stream_ref: ref} = state
      ) do
    # STALL watchdog, not a duration ceiling. The timer is armed once per turn;
    # when it fires we check whether the harness is legitimately busy:
    #
    #   * stream produced an event within the window → busy, slide the deadline
    #   * a TOOL CALL is in flight (active_tool set, no result yet) → busy:
    #     the ACP stream is EXPECTED to be silent while a long command runs
    #     (a multi-hour build streams nothing until it returns — observed live
    #     as hours-long turns killed mid-task). A dead adapter during a tool is
    #     caught by the port monitor (Adapter closed → stream_error), so the
    #     watchdog doesn't need to guess about process death — only about
    #     zombie streams, which don't hold a tool open.
    #
    # Only a stream that is silent AND idle-handed gets the reboot. No
    # last_stream_event_at (pre-hot-reload struct) → treat as stalled.
    now = System.monotonic_time(:millisecond)
    last = Map.get(state, :last_stream_event_at)
    silent_for = if is_integer(last), do: now - last, else: @stream_stall_ms
    busy? = silent_for < @stream_stall_ms or state.active_tool != nil

    if busy? do
      Process.send_after(self(), {:stream_timeout, id, ref}, @stream_stall_ms)
      {:noreply, state}
    else
      case StreamHandler.on_stream_timeout(state) do
        {:reboot, state} ->
          # Reboot the CLI with resume — clears the wedge, keeps the full chat
          # history, continues the conversation. Queued messages drain onto the
          # fresh CLI inside the restart path. A wedge counts toward the
          # compact-instead-of-resume breaker (restart_session's gate).
          state = SessionManager.note_cli_death(state)
          GenServer.cast(self(), :restart_session)
          {:noreply, state}
      end
    end
  end

  # Ignore timeout if ref doesn't match (stale timer from previous stream) or not thinking
  @impl true
  def handle_info({:stream_timeout, _id, _ref}, state), do: {:noreply, state}

  # Legacy timeout format (no ref) — ignore
  @impl true
  def handle_info({:stream_timeout, _id}, state), do: {:noreply, state}

  # Ref-tagged stream_error. Old stream's error — stream was already
  # superseded, no state action needed.
  def handle_info({:stream_error, _id, ref, _reason}, %{stream_ref: current_ref} = state)
      when ref != current_ref do
    {:noreply, state}
  end

  @impl true
  def handle_info({:stream_error, id, _ref, reason}, %{id: id} = state) do
    handle_info({:stream_error, id, reason}, state)
  end

  @impl true
  def handle_info({:stream_error, id, reason}, %{id: id} = state) do
    case StreamHandler.on_stream_error(state, reason) do
      {:build_resume, state} ->
        resume_msg = Loopyard.ChatAgent.ResumeMessage.build(state.messages)

        if resume_msg do
          GenServer.cast(self(), {:resume_prompt, resume_msg})
        end

        {:noreply, state}

      {:drain, list, state} ->
        send_batch(state, list)

      {:noreply, state} ->
        {:noreply, state}
    end
  end

  # Linked streaming task died — SessionManager.handle_thinking_exit auto-
  # restarts with backoff (crash-recovery lives there to keep this GenServer
  # thin). Without backoff, a deterministic crash hot-loops the harness API.
  @max_consecutive_crashes 5

  @impl true
  def handle_info({:EXIT, pid, reason}, %{status: :thinking} = state)
      when reason != :normal do
    if SessionManager.relevant_exit?(pid, state) do
      # Preserve any partial before backoff/restart (this crash path used to
      # skip finalization). Done here — not in SessionManager — so the
      # crash-recovery module doesn't depend on StreamHandler.
      state = StreamHandler.finalize_partial_on_stream_interrupt(state, state.id, :error)
      state = SessionManager.note_cli_death(state)
      SessionManager.handle_thinking_exit(reason, state, @max_consecutive_crashes)
    else
      # EXIT from an ALREADY-REPLACED session/task, not the current turn —
      # ignore it, or we'd replace the new healthy session and orphan a CLI.
      Loopyard.EventLog.info(
        "agent:#{state.name}",
        "Ignoring EXIT (#{inspect(reason)}) from stale process #{inspect(pid)} — not the current session/task"
      )

      {:noreply, state}
    end
  end

  # Scheduled by the :EXIT handler above after the backoff window.
  # Actually performs the session restart + appends the outcome
  # message. Kept out of the :EXIT handler so the mailbox stays
  # responsive during the backoff.
  #
  # Carries `dead_session` so we can detect whether ensure_session_alive
  # (running from a send_message cast mid-backoff) already replaced
  # state.session. If state.session != dead_session, a replacement
  # already happened — skip the retry so we don't orphan a CLI
  # process. Audit-2 HIGH #2.
  @impl true
  def handle_info({:retry_session, consecutive, dead_session}, state) do
    cond do
      state.session != dead_session and state.session != nil ->
        # Another path already replaced the session. No-op; the new
        # session is owned by whoever replaced it.
        Loopyard.EventLog.info(
          "agent:#{state.name}",
          "Skipped scheduled :retry_session (session already replaced by another path)"
        )

        state = Map.delete(state, :retry_from_session)
        {:noreply, state}

      compaction_breaker_tripped?(state) ->
        # The session this retry would resume keeps killing its harness —
        # route through :restart_session, whose breaker gate compacts
        # (summarize → fresh session) instead of resuming.
        GenServer.cast(self(), :restart_session)
        {:noreply, state}

      true ->
        SessionManager.handle_retry(state, consecutive, @max_consecutive_crashes)
    end
  end

  # Legacy 2-tuple form (older scheduled messages from before the
  # dead_session guard landed). Treat as a forced retry.
  @impl true
  def handle_info({:retry_session, consecutive}, state) do
    SessionManager.handle_retry(state, consecutive, @max_consecutive_crashes)
  end

  # Auth self-heal tick. An auth failure is NOT terminal: re-source credentials
  # by restarting the session (which re-reads the workstation env / home volume
  # and resumes the conversation). If the token is now valid the agent recovers;
  # if it's still bad, the next turn re-enters auth_expired and reschedules with
  # a longer backoff. Stale ticks (already recovered via a token-push reload, or
  # any other path) are dropped by the status guard.
  @impl true
  def handle_info({:auth_retry, _attempt}, %{status: status} = state)
      when status != :auth_expired do
    {:noreply, state}
  end

  def handle_info({:auth_retry, attempt}, state) do
    Loopyard.EventLog.info(
      "agent:#{state.name}",
      "Auth recovery retry ##{attempt} — re-sourcing credentials"
    )

    GenServer.cast(self(), :restart_session)
    {:noreply, state}
  end

  # Fired by handle_rate_limit_event. Don't optimistically attempt every interval
  # (that re-failed and re-appended unanswered messages, and spammed "window
  # cleared"). Instead: if the reset time hasn't passed yet, quietly reschedule —
  # nothing reaches the chat. Once the window has actually cleared, go idle and
  # drain whatever the user queued (silently, as one batched turn). The whole
  # rate limit lives at the turn-execution layer; the inbox never sees it beyond
  # the harness-status block.
  def handle_info({:rate_limit_retry, id}, %{id: id, status: :rate_limited} = state) do
    now = System.system_time(:millisecond)
    resets_at = state.rate_limit_resets_at_ms

    if is_integer(resets_at) and now < resets_at do
      Process.send_after(
        self(),
        {:rate_limit_retry, id},
        StreamHandler.compute_rate_limit_wait_ms(resets_at)
      )

      {:noreply, state}
    else
      state = %{
        state
        | status: :idle,
          rate_limit_status: :ok,
          rate_limit_resets_at_ms: nil,
          rate_limit_type: nil,
          rate_limit_utilization: nil
      }

      :ets.insert(@ets_table, {id, summary(state)})
      Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: id, status: :idle})

      case state.pending_sends do
        [] -> {:noreply, state}
        pending -> send_batch(%{state | pending_sends: []}, pending)
      end
    end
  end

  # Late/stale retry timer after status already moved on. No-op.
  def handle_info({:rate_limit_retry, _id}, state), do: {:noreply, state}

  # Idle-reap tick. Fires every :agent_idle_check_interval_ms (10 min
  # default). If the agent has been idle past the reap threshold AND
  # we have a captured claude_session_id (so the CLI can be rebuilt
  # via `resume:` with zero context loss), stop the CLI subprocess +
  # clear state.session + release the tracked OS pid. State stays
  # alive; the next :send_message goes through ensure_session_alive
  # and spawns a fresh CLI with resume. User-visible net: the agent
  # idle for 4h wakes up and continues the exact same conversation.
  # See agent-sanity #20.
  def handle_info(:idle_check, state) do
    # SELF-HEAL a stranded turn. A turn stuck in :thinking with no live session
    # can never finish — nothing streams, and its stall-watchdog ref may have
    # gone stale during a failed recovery — so without this it spins forever
    # until the user pokes it (a user hit exactly this: 9 minutes wedged). Route
    # through the normal recovery restart (fresh session + resume + drain of
    # pending sends). Time-guarded (@ghost_sweep_grace_ms) so a brief
    # session-swap window during a legit restart isn't mistaken for a wedge.
    if TurnHelpers.stranded_turn?(state, @ghost_sweep_grace_ms) do
      Logger.warning("[#{state.id}] self-healing stranded :thinking turn (idle sweep)")

      :telemetry.execute(
        [:loopyard, :agent, :ghost_turn_recovered],
        %{},
        %{agent_id: state.id, via: :idle_sweep}
      )

      GenServer.cast(self(), :restart_session)
    end

    state =
      if IdleReaper.eligible?(state) do
        Loopyard.EventLog.info(
          "agent:#{state.name}",
          "Reaping idle CLI subprocess (idle #{DateTime.diff(DateTime.utc_now(), state.last_activity_at, :second)}s, claude_session_id=#{String.slice(state.claude_session_id, 0..7)}…)"
        )

        :telemetry.execute(
          [:loopyard, :agent, :idle_reaped],
          %{idle_seconds: DateTime.diff(DateTime.utc_now(), state.last_activity_at, :second)},
          %{agent_id: state.id}
        )

        # Graceful CLI stop with a short cap — don't let a wedged CLI
        # block the reaper tick.
        SessionManager.stop_backend(state.session, state.backend)

        # Release the tracked OS pid so the Janitor drops its
        # reference. A second safety-kill by Resources.release isn't
        # needed — backend.stop already ended the process — but
        # clearing the entry keeps /system/orphans accurate.
        if state.tracked_cli_os_pid do
          Loopyard.Resources.release(:claude_cli, state.tracked_cli_os_pid)
        end

        # State keeps everything (messages, token totals, session_id)
        # — only the transient CLI connection is dropped.
        %{state | session: nil, tracked_cli_os_pid: nil}
      else
        state
      end

    # Mailbox-pressure observability. Piggybacks on the idle tick so
    # we don't add a second timer. Process.info(:message_queue_len) is
    # cheap. Threshold at 100 — normal operation keeps the mailbox <
    # 10 because handle_info drains as fast as events arrive; a
    # sustained 100+ means subscribers are slow or handle_info is
    # wedged. Telemetry-only (no status change); `/system/events`
    # picks it up for ops visibility.
    case Process.info(self(), :message_queue_len) do
      {:message_queue_len, n} when n >= 100 ->
        :telemetry.execute(
          [:loopyard, :agent, :mailbox_pressure],
          %{message_queue_len: n},
          %{agent_id: state.id}
        )

        Loopyard.EventLog.warning(
          "agent:#{state.name}",
          "Mailbox pressure: #{n} queued messages"
        )

      _ ->
        :ok
    end

    # Always reschedule — an agent that was reaped might later
    # receive a message, which will re-schedule after activity. But
    # keeping the tick running means we catch the next idle window
    # cleanly too (e.g. user opens then idles again).
    state = IdleReaper.schedule(state)
    {:noreply, state}
  end

  # Normal-reason EXITs from linked streaming Tasks: happen on every
  # successful turn when the stream Task's closure returns. trap_exit
  # converts these to messages. Without this explicit clause they
  # fell through to the unknown-message catch-all below, spamming
  # warning logs + telemetry on every stream. See audit-2 HIGH #1.
  def handle_info({:EXIT, _pid, :normal}, state), do: {:noreply, state}

  # Deliver messages that were queued (pending_sends) when the agent crashed,
  # once it has resumed with a fresh session. Scheduled from resume_from_summary
  # only when the restored queue is non-empty. pending_sends holds ONLY unsent
  # messages (send_batch clears them before sending), so this can't double-send.
  # The DECISION lives in ChatAgent.PendingDrain (pure, tested on its own); this
  # clause just performs it. Getting it wrong strands a message rather than
  # losing it — visible as "Queued" forever — which is far harder to spot.
  def handle_info(:drain_resumed_pending, state) do
    case Loopyard.ChatAgent.PendingDrain.decide(state) do
      :done ->
        {:noreply, Map.delete(state, :drain_attempts)}

      :drain ->
        pending = state.pending_sends
        send_batch(%{state | pending_sends: []} |> Map.delete(:drain_attempts), pending)

      {:retry, attempt, delay_ms} ->
        Process.send_after(self(), :drain_resumed_pending, delay_ms)
        {:noreply, Map.put(state, :drain_attempts, attempt)}

      {:give_up, attempt} ->
        Loopyard.EventLog.warning(
          "agent:#{state.name}",
          "#{length(state.pending_sends)} queued message(s) still undelivered after " <>
            "#{Loopyard.ChatAgent.PendingDrain.max_retries()} drain attempts (status #{state.status})"
        )

        {:noreply, Map.put(state, :drain_attempts, attempt)}
    end
  end

  def handle_info(msg, state) do
    Logger.warning("[ChatAgent] #{state.id} unhandled message: #{inspect(msg, limit: 200)}")

    :telemetry.execute(
      [:loopyard, :actor, :unknown_message],
      %{count: 1},
      %{actor: __MODULE__, agent_id: state.id, msg: inspect(msg, limit: 200)}
    )

    {:noreply, state}
  end

  # dispatch_retry_session — extracted to SessionManager.handle_retry/3

  @impl true
  def terminate(_reason, state) do
    # Always TRY a clean shutdown of the SDK session — a graceful
    # protocol exit is preferable to a SIGKILL and lets the CLI flush
    # any pending writes. Cap at 3s so we never block the supervisor.
    SessionManager.stop_backend(state.session, state.backend)

    # We do NOT manually SIGKILL the CLI OS process here. It's tracked
    # via Loopyard.Resources.track(:claude_cli, os_pid) so the Janitor
    # receives our DOWN message (sent on any exit reason, including
    # :normal) and runs the release fn — SIGKILL if still alive, no-op
    # if the clean shutdown above already ended it. This also covers
    # the paths where `terminate/2` never runs (brutal_kill, node
    # crash, :shutdown-timeout exceeded) — the main reason surface #12
    # exists.

    # Don't overwrite the ETS row with :crashed if the operator already
    # marked us :stopped or :destroying. `stop_agent/1` updates ETS to
    # :stopped, broadcasts, THEN calls GenServer.stop — but our
    # in-process `state.status` was never updated (no message was
    # processed in between), so checking only `state.status` flips a
    # clean :stopped back to :crashed. ETS is the source of truth;
    # respect it.
    intentional_stop? =
      state.status in [:stopped, :destroying] or
        case :ets.lookup(@ets_table, state.id) do
          [{_, %{status: s}}] when s in [:stopped, :destroying] -> true
          _ -> false
        end

    unless intentional_stop? do
      crashed = %{state | status: :crashed}
      :ets.insert(@ets_table, {state.id, summary(crashed)})
      Events.ChatAgent.publish(%Events.ChatAgent.Stopped{summary: summary(crashed)})
    end
  end

  # --- Private ---

  # Ensure whatever session_opts we hand to the backend carry the
  # latest Claude CLI session_id as `resume:`. This is what makes a
  # respawned CLI continue the same conversation instead of booting
  # fresh. Called on every code path that restarts the session —
  # :restart_session cast, crash-recovery, retry-after-backoff,
  # ensure_session_alive.
  # ghost_thinking?/reset_ghost_turn/warm_interrupt — extracted to
  # Loopyard.ChatAgent.TurnHelpers.

  defp send_message_normal(state, text) do
    state = SessionManager.ensure_alive(state)

    if not state.backend.session_alive?(state.session) do
      # ensure_alive/1 just tried to (re)spawn the CLI and it's STILL dead.
      # Do NOT silently drop the message (the "swallow" bug) — but do NOT
      # fire a red error either: we're about to kick a restart that heals in
      # a second or two the vast majority of the time, and narrating a fast
      # recovery with a scary error is the anti-pattern. So: queue the RAW
      # text (drain_pending_sends re-runs this fn, appending the user message
      # exactly once when a live session finally takes it), drop ONE quiet
      # system line, and kick the restart. If recovery genuinely fails, the
      # user isn't left guessing — the sidebar harness-status block shows
      # "offline/reconnecting" and a crash-looping session is quarantined
      # (/system/quarantine). The loud escalation lives on those paths, not
      # here, ahead of a recovery that usually just works.
      # SILENT: the restart auto-fixes and auto-delivers — the queue band shows
      # the parked message and harness-status shows Reconnecting. A chat line
      # about self-healing is noise ("it either broke or it didn't").
      Loopyard.EventLog.info(
        "agent:#{state.name}",
        "send hit a dead session — queued + restarting"
      )

      state =
        case SendGuards.park_send(state, text) do
          {:ok, state} -> state
          :full -> SendGuards.queue_full_note(state)
        end

      state = %{state | status: :booting}
      :ets.insert(@ets_table, {state.id, summary(state)})
      Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: state.id, status: :booting})
      GenServer.cast(self(), :restart_session)
      {:noreply, state}
    else
      user_msg = %{role: :user, content: text, timestamp: DateTime.utc_now()}
      {state, user_msg} = append_message(state, user_msg)
      Persistence.persist_message(state, user_msg)

      Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{
        agent_id: state.id,
        msg: user_msg
      })

      # Fresh human turn → reset the transient-retry counter and any prior
      # failed-prompt banner.
      start_turn(
        %{state | turn_retry_count: 0, failed_prompt: nil, current_turn_origin: :human},
        text
      )
    end
  end

  # Drain a parked flurry: show the user's ACTUAL individual messages in the
  # chat, but stream the FRAMED batch (Turn.batch_prompt) as the prompt — so the
  # history reads like what you typed, and only the model sees the "you sent N
  # messages…" framing. A single message takes the normal path.
  defp send_batch(state, [single]), do: send_message_normal(state, single)

  defp send_batch(state, list) when is_list(list) do
    state = SessionManager.ensure_alive(state)

    if not state.backend.session_alive?(state.session) do
      # Dead at drain time — re-queue the whole flurry and restart; never lose it.
      state = %{state | pending_sends: list, status: :booting}
      :ets.insert(@ets_table, {state.id, summary(state)})
      Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: state.id, status: :booting})
      GenServer.cast(self(), :restart_session)
      {:noreply, state}
    else
      state =
        Enum.reduce(list, state, fn text, st ->
          msg = %{role: :user, content: text, timestamp: DateTime.utc_now()}
          {st, msg} = append_message(st, msg)
          Persistence.persist_message(st, msg)

          Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{
            agent_id: st.id,
            msg: msg
          })

          st
        end)

      start_turn(
        %{state | turn_retry_count: 0, failed_prompt: nil, current_turn_origin: :human},
        Loopyard.Turn.batch_prompt(list)
      )
    end
  end

  # Start the agent's turn: stream `prompt` to the backend, tagged with a fresh
  # stream_ref. This is the turn machine's `{:start_turn, prompt}` effect made
  # concrete; it does NOT append a user message (the caller decides what to show,
  # which is what lets a batch display individual messages but stream the framed
  # prompt). stream_ref is generated BEFORE the Task so every event is tagged
  # with the ref identifying THIS stream — a replaced session's stale events are
  # dropped by ref on the other side (agent-sanity #16).
  defp start_turn(state, prompt) do
    state = %{state | status: :thinking}
    :ets.insert(@ets_table, {state.id, summary(state)})
    Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: state.id, status: :thinking})

    stream_ref = make_ref()
    me = self()
    agent_id = state.id
    session = state.session
    backend = state.backend

    {:ok, task_pid} =
      Task.start_link(fn ->
        try do
          backend.stream(session, prompt)
          |> Enum.each(fn event ->
            send(me, {:stream_event, agent_id, stream_ref, event})
          end)

          send(me, {:stream_done, agent_id, stream_ref})
        rescue
          e ->
            send(me, {:stream_error, agent_id, stream_ref, Exception.message(e)})
        catch
          :exit, reason ->
            send(
              me,
              {:stream_error, agent_id, stream_ref, "CLI session exited: #{inspect(reason)}"}
            )
        end
      end)

    Process.send_after(self(), {:stream_timeout, agent_id, stream_ref}, @stream_stall_ms)
    # Stash the exact prompt so a transient-failure retry re-issues it verbatim.
    {:noreply,
     %{
       state
       | stream_ref: stream_ref,
         stream_task_pid: task_pid,
         in_flight_partial: "",
         current_turn_prompt: prompt
     }
     |> Map.put(:last_stream_event_at, System.monotonic_time(:millisecond))}
  end

  # Append via the ONE shared MessageLog (id assignment + message cap).
  defp append_message(state, msg), do: MessageLog.append(state, msg)

  @doc false
  def summary(state), do: Summary.build(state)

  @doc "Drop all queued (pending) messages without stopping the current turn."
  defdelegate clear_pending(id), to: Client

  @doc "Warm-interrupt the in-flight turn (keep the session); sleep the agent if idle."
  defdelegate interrupt(id), to: Client

  @doc "Remove a single queued message by its index in the pending queue."
  defdelegate remove_pending(id, index), to: Client

  @doc "Edit a queued message in place (preserves position; guarded by old_text)."
  defdelegate update_pending(id, index, old_text, new_text), to: Client

  # All broadcast from ChatAgent is done through the typed publisher
  # modules `Loopyard.Events.ChatAgent` (topic `"chat_agents"`) and
  # `Loopyard.Events.ChatAgentMessage` (topic `"chat_agent:{id}"`).
  # The CI boundary test enforces that no other code path calls
  # Phoenix.PubSub.broadcast directly.

  # --- Delegated public API ---

  @doc false
  defdelegate build_system_prompt(agent_id, opts), to: Prompt
end
