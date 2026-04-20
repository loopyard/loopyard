defmodule BoomLooper.ChatAgent do
  @moduledoc """
  GenServer wrapping a Claude Code SDK session.
  Streams structured messages to viewers via PubSub.
  Unlike the PTY-based Agent, this uses the JSON protocol
  for a proper multiplayer chat experience.
  """ # Force recompile: 2026-03-26T14:55
  # :temporary — the DynamicSupervisor never auto-restarts. The
  # BoomLooper.ChatAgent.RestartController GenServer owns every
  # respawn decision synchronously, which gives us exact quarantine
  # semantics: the Nth crash quarantines before the N+1th can occur.
  # See plans/coordination-hardening.md Move #10.
  use GenServer, restart: :temporary
  require Logger

  alias BoomLooper.Agent.Event
  alias BoomLooper.AgentLog
  alias BoomLooper.ChatAgent.{Persistence, Prompt, ToolConfig}
  alias BoomLooper.Events


  defstruct [
    :id,
    :name,
    :session,
    :session_opts,
    :backend,
    :working_dir,
    :bind_mount,
    :workspace_id,
    :started_at,
    :started_by,
    :last_activity_at,
    :service_name,
    :agent_type,
    :claude_session_id,
    status: :idle,
    messages: [],
    tool_calls: 0,
    errors: 0,
    stream_ref: nil,
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
    auth_error: nil,
    # OS pid of the Claude CLI subprocess owned by state.session. Tracked
    # via BoomLooper.Resources.track/4 so the Janitor kills it on our
    # DOWN — covers the brutal_kill / node crash / :shutdown-timeout
    # cases where `terminate/2` never runs. See plans/agent-sanity.md #12.
    tracked_cli_os_pid: nil,
    # SHA-256 of the system_prompt passed to `append_system_prompt` on
    # start_session. Stored alongside claude_session_id so init_resume
    # can detect when the prompt has changed between boots (CLAUDE.md
    # edit, tool set updated, agent_type reassigned). When it differs,
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
    in_flight_partial: ""
  ]

  @ets_table :chat_agents

  # Hard cap on a single :send_message cast payload. Claude's own
  # limit is much higher (context-window-bound) but any single 1MB
  # input is almost certainly a paste mistake, a runaway automation,
  # or a tool feeding back its own output. Rejecting here protects:
  # the agent mailbox, PubSub broadcast fanout to every viewer, and
  # the Claude API bill. Configurable via Application env for tests
  # that want to exercise the reject path with smaller inputs.
  @max_message_bytes Application.compile_env(:boom_looper, :max_message_bytes, 1_048_576)

  # Loop-detection threshold: if the agent calls the same tool with
  # the same input N times in a row, it's almost certainly stuck in a
  # retry loop (tool returning the same error, agent interpreting the
  # error the same way, agent re-calling). 5 is generous enough to not
  # trip on legitimate retry patterns but tight enough to surface
  # before the user burns another $5 of tokens watching it grind.
  @tool_loop_threshold 5

  # Runaway cap: total tool calls in a single turn before we warn
  # the user. Most legitimate turns make 5-20 tool calls (context
  # gathering, edits, runs). 50 is a generous ceiling — past that
  # it's almost certainly a loop the agent is stuck in, even if
  # each call is technically different.
  @turn_tool_limit 50

  # --- Public API ---

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: via(id))
  end

  def send_message(id, text) do
    GenServer.cast(via(id), {:send_message, text})
  end


  def get_state(id) do
    # Try live GenServer first, fall back to ETS. Short timeout (500ms)
    # because this is a read path from the UI: a wedged agent doesn't
    # deserve a 5-second UI hang when the ETS summary is right there.
    # The fall-through via `catch :exit, _` handles both "no such
    # agent" (noproc) and "agent wedged / took >500ms" — both recover
    # cleanly from ETS.
    try do
      GenServer.call(via(id), :get_state, 500)
    catch
      :exit, _ ->
        case :ets.lookup(@ets_table, id) do
          [{^id, summary}] -> summary
          [] -> nil
        end
    end
  end

  def stop_agent(id) do
    case Registry.lookup(BoomLooper.ChatAgentRegistry, id) do
      [{pid, _}] ->
        # Update ETS and broadcast before stopping, since terminate(:normal) is a no-op
        case :ets.lookup(@ets_table, id) do
          [{^id, summary}] ->
            stopped = %{summary | status: :stopped}
            :ets.insert(@ets_table, {id, stopped})
            Events.ChatAgent.publish(%Events.ChatAgent.Stopped{summary: stopped})

          [] ->
            :ok
        end

        # Force-stop the GenServer (kills linked streaming task too).
        # Guard with Process.alive? so already-dead pids short-circuit
        # — without the guard, GenServer.stop/3 on a noproc raises an
        # exit that callers have to rescue. Matters most for AgentBoot
        # rollback, where the agent is often already dying; the stop
        # used to wait 5s for a no-op.
        if Process.alive?(pid) do
          GenServer.stop(pid, :normal, 5_000)
        else
          :ok
        end

      [] ->
        :ok
    end
  end

  def rename(id, new_name) do
    GenServer.cast(via(id), {:rename, new_name})
  end

  @doc "Get a specific message by ID from the agent's ETS state."
  def get_message(agent_id, msg_id) do
    case get_state(agent_id) do
      %{messages: messages} -> Enum.find(messages, &(&1[:id] == msg_id))
      _ -> nil
    end
  end

  @doc "Append a message to an agent's message list (for stream messages created outside the GenServer).
  Goes through the GenServer if alive, falls back to direct ETS write."
  def append_message_ets(agent_id, msg) do
    msg = Map.put_new_lazy(msg, :id, fn -> generate_msg_id() end)

    case Registry.lookup(BoomLooper.ChatAgentRegistry, agent_id) do
      [{pid, _}] ->
        GenServer.cast(pid, {:append_external_message, msg})
        msg

      [] ->
        # No GenServer running — direct ETS write
        case :ets.lookup(@ets_table, agent_id) do
          [{^agent_id, summary}] ->
            :ets.insert(@ets_table, {agent_id, %{summary | messages: summary.messages ++ [msg]}})
            msg
          [] -> nil
        end
    end
  end

  @doc "Update a message by ID. Goes through GenServer if alive, falls back to direct ETS."
  def update_message(agent_id, msg_id, update_fn) do
    case Registry.lookup(BoomLooper.ChatAgentRegistry, agent_id) do
      [{pid, _}] ->
        GenServer.cast(pid, {:update_message, msg_id, update_fn})
        :ok

      [] ->
        case :ets.lookup(@ets_table, agent_id) do
          [{^agent_id, summary}] ->
            messages = Enum.map(summary.messages, fn msg ->
              if msg[:id] == msg_id, do: update_fn.(msg), else: msg
            end)
            :ets.insert(@ets_table, {agent_id, %{summary | messages: messages}})
            :ok
          [] -> :error
        end
    end
  end

  @doc "Restart the Claude CLI session without losing the agent or its messages"
  def restart_session(id) do
    GenServer.cast(via(id), :restart_session)
  end

  @doc "Start a stopped/crashed agent — starts a new GenServer and resumes from saved state"
  def start_agent(id) do
    case :ets.lookup(@ets_table, id) do
      [] ->
        {:error, "Agent not found"}

      [{^id, summary}] ->
        # The REAL check is whether a GenServer is actually running. ETS
        # status can be stale after a crash (still :idle even though the
        # process is gone). Registry is authoritative about liveness.
        case agent_alive?(id) do
          true ->
            {:error, "Agent already running"}

          false ->
            do_start_agent(id, summary)
        end
    end
  end

  defp agent_alive?(id) do
    case Registry.lookup(BoomLooper.ChatAgentRegistry, id) do
      [{pid, _}] -> Process.alive?(pid)
      _ -> false
    end
  end

  defp do_start_agent(id, summary) do
    opts =
      [
        id: id,
        name: summary.name,
        working_dir: summary[:working_dir],
        bind_mount: summary[:bind_mount],
        workspace_id: summary[:workspace_id],
        volume: summary[:volume],
        resume: true
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    supervisor =
      if summary[:workspace_id] do
        BoomLooper.WorkspaceGroup.agent_sup_name(summary[:workspace_id])
      else
        BoomLooper.AgentSupervisor
      end

    case DynamicSupervisor.start_child(supervisor, {__MODULE__, opts}) do
      {:ok, _pid} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Remove a stopped/crashed agent — transitions to :destroying, cleans up Docker, then removes from sidebar"
  def remove_agent(id) do
    # Transition to :destroying via the StateMachine so we reject the
    # "remove → restart → remove again" race: once an agent is
    # :destroying, a second remove_agent call is a no-op instead of
    # re-broadcasting and re-entering cleanup.
    case :ets.lookup(@ets_table, id) do
      [{^id, %{status: :destroying}}] ->
        :ok

      [{^id, summary}] ->
        case BoomLooper.ChatAgent.StateMachine.transition(summary.status, :destroying) do
          {:ok, :destroying} ->
            destroying = %{summary | status: :destroying}
            :ets.insert(@ets_table, {id, destroying})
            Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: id, status: :destroying})

          {:error, reason} ->
            BoomLooper.EventLog.warning(
              "agent:#{summary[:name] || id}",
              "remove_agent: invalid status transition #{inspect(reason)} — " <>
                "proceeding with cleanup anyway"
            )

            destroying = %{summary | status: :destroying}
            :ets.insert(@ets_table, {id, destroying})
            Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: id, status: :destroying})
        end

      [] ->
        :ok
    end

    # Persist removal to agent log so it's not replayed on restart
    case :ets.lookup(@ets_table, id) do
      [{^id, summary}] ->
        ws_id = summary[:workspace_id]
        if ws_id do
          path = Persistence.log_path(ws_id)
          AgentLog.append({:agent_removed, id}, log_path: path, version: 1)
        end
      [] -> :ok
    end

    # Remove from sidebar
    :ets.delete(@ets_table, id)
    Events.ChatAgent.publish(%Events.ChatAgent.Removed{id: id})
  end

  @doc "Register an agent as booting in ETS so all viewers can see it"
  def register_booting(id, name, working_dir, opts \\ []) do
    # Go through summary/1 so the booting entry carries every field
    # summary exposes — tokens (0.0), cost, model (nil), turns, etc.
    # Same reason as init_resume: the UI reads these unconditionally
    # and a partial map would surface as KeyError or zeroed values
    # that look real.
    now = DateTime.utc_now()

    stub = %__MODULE__{
      id: id,
      name: name,
      working_dir: working_dir,
      service_name: Keyword.get(opts, :service_name),
      started_at: now,
      started_by: "browser",
      last_activity_at: now,
      status: :booting
    }

    summary = stub |> summary() |> Map.put(:boot_status, "Initializing...")

    :ets.insert(@ets_table, {id, summary})
    Events.ChatAgent.publish(%Events.ChatAgent.Booting{summary: summary})
    summary
  end

  @doc "Update boot status in ETS and broadcast to all viewers"
  def update_boot_status(id, status_text) do
    case :ets.lookup(@ets_table, id) do
      [{^id, summary}] ->
        updated = %{summary | boot_status: status_text, last_activity_at: DateTime.utc_now()}
        :ets.insert(@ets_table, {id, updated})
        Events.ChatAgent.publish(%Events.ChatAgent.BootStatus{id: id, status: status_text})

      [] ->
        :ok
    end
  end

  @doc "Mark a booting agent as failed and remove it"
  def boot_failed(id, reason) do
    :ets.delete(@ets_table, id)
    Events.ChatAgent.publish(%Events.ChatAgent.BootFailed{id: id, reason: reason})
  end

  # How long an agent is allowed to stay in :booting before we
  # conclude its boot Task died without running its failure handler
  # (task supervisor shutdown, OS kill, etc.) and forcibly surface
  # it as :crashed so the UI's Start button appears. Anything under
  # this window is still legitimately booting.
  @stuck_booting_seconds 300

  def list_agents do
    :ets.tab2list(@ets_table)
    |> Enum.map(fn {_id, summary} ->
      # If agent is still alive, get fresh state
      case Registry.lookup(BoomLooper.ChatAgentRegistry, summary.id) do
        [{pid, _}] ->
          try do
            # 500ms timeout matches get_state/1 — a wedged agent
            # shouldn't block the whole list_agents call while the UI
            # waits. ETS summary is the fallback.
            GenServer.call(pid, :get_state, 500)
          catch
            :exit, _ -> summary
          end

        [] ->
          # No live GenServer. If the summary claims :booting and it's
          # been sitting there longer than @stuck_booting_seconds, the
          # boot task has almost certainly died without running its
          # rescue/catch clauses (TaskSupervisor shutdown, OS kill,
          # etc). Present it as :crashed so the user sees a real
          # action (Start/Remove) instead of a perpetual spinner.
          if stuck_booting?(summary) do
            %{summary | status: :crashed}
          else
            summary
          end
      end
    end)
    # Agents without a started_at (e.g. test-seeded ETS rows, half-
    # populated boot state) would crash `DateTime.compare/2`. Treat
    # missing timestamps as "oldest" so sort is total and safe.
    |> Enum.sort_by(
      & &1[:started_at],
      fn
        nil, nil -> true
        nil, _ -> false
        _, nil -> true
        a, b -> DateTime.compare(a, b) != :lt
      end
    )
  end

  def subscribe do
    BoomLooper.Events.ChatAgent.subscribe()
  end

  def subscribe(agent_id) do
    BoomLooper.Events.ChatAgentMessage.subscribe(agent_id)
  end

  def unsubscribe(agent_id) do
    BoomLooper.Events.ChatAgentMessage.unsubscribe(agent_id)
  end

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
    resume = Keyword.get(opts, :resume, false)

    if resume do
      init_resume(id, opts)
    else
      init_fresh(id, opts)
    end
  end

  # Resume an agent from persisted state (after server restart).
  #
  # Rebuild the struct from the saved summary verbatim, then overlay
  # the runtime fields that don't persist (session, backend, etc).
  # Past bug: hand-listing fields dropped `total_input_tokens`,
  # `total_cost_usd`, `model`, `turns` — every resume silently zeroed
  # the Claude panel. The general rule: summary is the contract.
  # `struct(__MODULE__, saved)` ignores summary-only keys and fills
  # missing defstruct fields with defaults, so adding a field to
  # `summary/1` and the struct is enough — no resume update needed.
  defp init_resume(id, opts) do
    case :ets.lookup(@ets_table, id) do
      [{^id, saved}] ->
        case validate_resume_summary(id, saved) do
          :ok ->
            resume_from_summary(id, opts, saved)

          {:error, missing_fields} ->
            BoomLooper.EventLog.error(
              "agent:#{id}",
              "Refusing to resume: saved summary missing required fields #{inspect(missing_fields)}. " <>
                "The ETS row is corrupt or the schema drifted. Remove this agent and recreate."
            )

            :telemetry.execute(
              [:boom_looper, :agent, :resume_rejected],
              %{count: 1},
              %{agent_id: id, missing_fields: missing_fields}
            )

            # Don't silently boot with nil fields; stop and let the
            # supervisor report the error. This is preferable to
            # starting with broken state that crashes on first use.
            {:stop, {:corrupted_resume_state, missing_fields}}
        end

      [] ->
        {:stop, :no_saved_state}
    end
  end

  # Minimum fields we need to safely resume. Missing `working_dir` ==
  # can't start a CLI; missing `name` == unusable sidebar entry;
  # missing `started_at` == sort ordering crashes. Other fields like
  # tokens/cost/messages are optional-with-defaults and don't need
  # validation.
  defp validate_resume_summary(_id, saved) do
    required = [:working_dir, :name, :started_at]

    missing =
      Enum.filter(required, fn field ->
        case Map.get(saved, field) do
          nil -> true
          "" -> true
          _ -> false
        end
      end)

    case missing do
      [] -> :ok
      fields -> {:error, fields}
    end
  end

  defp resume_from_summary(id, opts, saved) do
    agent_type = saved[:agent_type] || BoomLooper.Agents.Registry.default_agent_name()

    {session, session_opts, backend, new_prompt_hash} =
      start_session(id, opts,
        working_dir: saved.working_dir,
        bind_mount: saved.bind_mount,
        workspace_id: saved.workspace_id,
        service_name: saved[:service_name],
        agent_type: agent_type,
        claude_session_id: saved[:claude_session_id]
      )

    # Prompt-drift detection — agent-sanity #19. If the system prompt
    # hash differs from the one captured last boot, the agent's
    # behavior may change subtly from its earlier turns. Detect it
    # here, surface it below after state is built.
    saved_prompt_hash = saved[:prompt_hash]

    prompt_changed? =
      is_binary(saved_prompt_hash) and is_binary(new_prompt_hash) and
        saved_prompt_hash != new_prompt_hash

    # Summary stores messages oldest-first (display order); internal
    # state stores them newest-first for O(1) prepend in append_message.
    # Reverse back on load or the message list grows in the wrong
    # direction across restart.
    internal_messages = Enum.reverse(saved[:messages] || [])

    state =
      __MODULE__
      |> struct(saved)
      |> struct(
        session: session,
        session_opts: session_opts,
        backend: backend,
        last_activity_at: DateTime.utc_now(),
        status: :idle,
        stream_ref: nil,
        active_tool: nil,
        agent_type: agent_type,
        messages: internal_messages,
        # Drop any stale tracked pid from the saved summary — the old
        # CLI OS pid is long dead from the previous BEAM. track_cli_os_pid
        # below registers the new one with the Janitor.
        tracked_cli_os_pid: nil,
        prompt_hash: new_prompt_hash
      )

    state = track_cli_os_pid(state)
    state = schedule_idle_check(state)

    # Agent-sanity #19 — prompt drift marker. Announce the change in
    # the conversation so the user isn't mystified if the agent
    # behaves differently than it did pre-boot.
    state =
      if prompt_changed? do
        :telemetry.execute(
          [:boom_looper, :agent, :prompt_drift],
          %{count: 1},
          %{agent_id: id, old_hash: saved_prompt_hash, new_hash: new_prompt_hash}
        )

        BoomLooper.EventLog.info(
          "agent:#{id}",
          "Prompt drift detected (old=#{String.slice(saved_prompt_hash, 0..7)} " <>
            "new=#{String.slice(new_prompt_hash, 0..7)})"
        )

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
        Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{agent_id: id, msg: drift_msg})
        state
      else
        state
      end

    :ets.insert(@ets_table, {id, summary(state)})
    Events.ChatAgent.publish(%Events.ChatAgent.Resumed{summary: summary(state)})

    # Emit resume visibility via EventLog only — do NOT inject a
    # system message into the conversation here. An injected
    # message would (a) pollute message-ordering and cap tests,
    # (b) insert itself between persisted user turns on replay,
    # and (c) be confusing for agents that resumed cleanly with
    # a valid claude_session_id (no user-facing event worth
    # surfacing in-chat).
    context_status =
      cond do
        is_binary(state.claude_session_id) -> "conversation continued"
        length(state.messages) > 0 -> "NO claude_session_id — CLI will start fresh"
        true -> "no prior messages"
      end

    BoomLooper.EventLog.info(
      "agent:#{state.name}",
      "Resumed (#{id}) with #{length(state.messages)} messages, #{context_status}"
    )

    {:ok, state}
  end

  # Start a fresh agent (normal path)
  defp init_fresh(id, opts) do
    name = Keyword.get(opts, :name, "Chat #{id |> String.slice(0..7)}")
    working_dir = Keyword.get(opts, :working_dir, File.cwd!())
    started_by = Keyword.get(opts, :started_by, "anonymous")
    bind_mount = Keyword.get(opts, :bind_mount)
    workspace_id = Keyword.get(opts, :workspace_id)
    service_name = Keyword.get(opts, :service_name)
    agent_type = Keyword.get(opts, :agent_type) || BoomLooper.Agents.Registry.default_agent_name()

    {session, session_opts, backend, prompt_hash} = start_session(id, opts,
      working_dir: working_dir,
      bind_mount: bind_mount,
      workspace_id: workspace_id,
      service_name: service_name,
      agent_type: agent_type,
      max_turns: 50
    )

    now = DateTime.utc_now()

    state = %__MODULE__{
      id: id,
      name: name,
      session: session,
      session_opts: session_opts,
      backend: backend,
      working_dir: working_dir,
      bind_mount: bind_mount,
      workspace_id: workspace_id,
      started_at: now,
      started_by: started_by,
      last_activity_at: now,
      status: :idle,
      messages: [],
      service_name: service_name,
      agent_type: agent_type,
      prompt_hash: prompt_hash
    }

    state = track_cli_os_pid(state)
    state = schedule_idle_check(state)
    summary = summary(state)
    :ets.insert(@ets_table, {id, summary})
    Persistence.persist_agent(state, &summary/1)
    Events.ChatAgent.publish(%Events.ChatAgent.Started{summary: summary})
    BoomLooper.EventLog.info("agent:#{name}", "Started (#{id})")

    {:ok, state}
  end

  # Shared session creation for both fresh and resumed agents
  defp start_session(id, opts, params) do
    working_dir = Keyword.fetch!(params, :working_dir)
    bind_mount = Keyword.get(params, :bind_mount)
    workspace_id = Keyword.get(params, :workspace_id)
    service_name = Keyword.get(params, :service_name)
    agent_type = Keyword.get(params, :agent_type) || BoomLooper.Agents.Registry.default_agent_name()
    # When we've seen this agent before (server restart, CLI crash,
    # auto-reconnect), `claude_session_id` is the Claude CLI's own
    # conversation id captured from the last ResultMessage. Passing it
    # as `resume:` tells the CLI to continue the same thread instead of
    # starting amnesiac with a fresh system prompt. Without this, each
    # respawn forgets everything the user + the 455 messages we
    # preserved in the agent log.
    resume_session_id = Keyword.get(params, :claude_session_id)

    tools = Keyword.get(opts, :tools, ToolConfig.default_tools())

    # Backend defaults: opts override > app config > ClaudeCode.
    # Tests set `:default_agent_backend` to `BoomLooper.Agent.Backend.Fake`
    # in config/test.exs so any test that boots a ChatAgent without an
    # explicit override gets a no-op backend instead of timing out on
    # the real CLI.
    default_backend =
      Application.get_env(:boom_looper, :default_agent_backend, BoomLooper.Agent.Backend.ClaudeCode)

    backend = Keyword.get(opts, :backend, default_backend)
    workspace = if workspace_id, do: load_workspace_config(workspace_id), else: nil

    system_prompt =
      Prompt.build_system_prompt(id,
        bind_mount: bind_mount,
        workspace_id: workspace_id,
        workspace: workspace,
        service_name: service_name,
        agent_type: agent_type
      )

    # Mirror CLAUDE.md + .claude/ from the workspace volume into working_dir
    # (a no-op for Local workspaces where Mutagen already puts them on the
    # host). The Claude Code CLI does its own discovery from cwd, so after
    # this runs the agent sees the same project memory a human would get
    # from running `claude` in that repo.
    if workspace_id do
      BoomLooper.ChatAgent.ClaudeContext.mirror(workspace_id, working_dir)
    end

    # Containerized agents (volume-based, no bind_mount) MUST NOT use
    # host-side filesystem tools. Their workspace lives inside a Docker
    # volume; the host's view of `working_dir` is empty. If a container
    # agent has Bash/Read/Edit/Write/Glob/Grep, it falls back to the
    # BEAM process cwd (the BoomLooper repo) and merrily edits files
    # there — which never reaches the running dev container.
    #
    # We saw this twice:
    # - chatwoot eval cross-contamination (set up BoomLooper instead of chatwoot)
    # - "change a UI string" reproducer (edited a stale host clone, not the
    #   docker volume the container reads)
    #
    # `allowed_tools` alone isn't enough: with --dangerously-skip-permissions,
    # the SDK still allows native tools by default. We need an EXPLICIT
    # disallowed_tools list to block them.
    #
    # Bind-mount agents keep the native tools because they legitimately
    # work on the host dir.
    container_only? = is_nil(bind_mount)

    # `append_system_prompt` preserves the CLI's default system prompt
    # (which handles CLAUDE.md auto-discovery, slash command docs, native
    # tool descriptions, etc.) and appends our BoomLooper-specific rules
    # on top. Using `system_prompt` would REPLACE the default and the
    # agent would stop seeing CLAUDE.md and other native context.
    base_opts = [
      cwd: working_dir,
      permission_mode: :accept_edits,
      dangerously_skip_permissions: true,
      mcp_servers: ToolConfig.build_mcp_servers(tools, id),
      allowed_tools: ToolConfig.build_allowed_tools(tools, container_only?),
      append_system_prompt: system_prompt
    ]

    session_opts =
      if container_only? do
        Keyword.put(base_opts, :disallowed_tools, ToolConfig.denied_native_tools_for_container_agents())
      else
        base_opts
      end

    session_opts = if max = Keyword.get(params, :max_turns),
      do: Keyword.put(session_opts, :max_turns, max),
      else: session_opts

    session_opts =
      if is_binary(resume_session_id) and resume_session_id != "" do
        Keyword.put(session_opts, :resume, resume_session_id)
      else
        session_opts
      end

    # backend.start_session/1 can fail with {:error, reason} — the CLI
    # binary missing, auth failing before the first byte, an OS-level
    # resource limit. Raising with a clear message here is better than
    # the MatchError on {:error, _} this previously emitted: the
    # supervisor log names the reason instead of the line number.
    case backend.start_session(session_opts) do
      {:ok, session} ->
        prompt_hash = :crypto.hash(:sha256, system_prompt || "") |> Base.encode16(case: :lower)
        {session, session_opts, backend, prompt_hash}

      {:error, reason} ->
        raise RuntimeError,
          message:
            "Failed to start CLI session for agent #{id}: #{inspect(reason)}. " <>
              "Usually this means: the `claude` binary isn't on PATH, the workspace volume " <>
              "is unreachable, or auth isn't configured. Run " <>
              "`mix boom.rpc 'ClaudeCode.Test.smoke()'` to diagnose."
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
      [:boom_looper, :agent, :message_rejected],
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

  def handle_cast({:send_message, text}, state) when is_binary(text) and byte_size(text) > @max_message_bytes do
    # Reject oversized input before it hits any stream. A 50MB paste
    # would otherwise: blow up ETS term size, trigger huge PubSub
    # broadcasts to every viewer, burn a turn at maximum Claude cost,
    # and potentially crash the mailbox with message-too-big. Much
    # better to refuse cleanly.
    :telemetry.execute(
      [:boom_looper, :agent, :message_rejected],
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
    Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{agent_id: state.id, msg: reject_msg})
    {:noreply, state}
  end

  def handle_cast({:send_message, text}, state) do
    :telemetry.execute([:boom_looper, :agent, :message], %{}, %{agent_id: state.id, role: :user})

    cond do
      # Agent-sanity #15. If a turn is already in flight (:thinking)
      # or pending restart (:backoff), starting a second stream Task
      # against the same Claude session risks interleaved events or
      # an error from the SDK's query_queue. Record the message so
      # the user sees it didn't vanish, then enqueue for
      # post-turn drain. The turn-completion handlers
      # (:stream_done / :stream_error / :stream_timeout) pop the
      # queue and resume sends in order.
      state.status in [:thinking, :backoff] ->
        user_msg = %{role: :user, content: text, timestamp: DateTime.utc_now()}
        {state, user_msg} = append_message(state, user_msg)
        Persistence.persist_message(state, user_msg)
        Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{agent_id: state.id, msg: user_msg})

        state = %{state | pending_sends: state.pending_sends ++ [text]}

        queued_msg = %{
          role: :system,
          content:
            "Queued — agent is still working on the previous turn. Will process after it finishes.",
          timestamp: DateTime.utc_now()
        }
        {state, queued_msg} = append_message(state, queued_msg)
        Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{agent_id: state.id, msg: queued_msg})
        {:noreply, state}

      state.status == :rate_limited ->
        # Don't hammer the API while we're rate-limited. The send was
        # worth recording (so the user sees their message in the log)
        # but we skip the CLI roundtrip — it would just emit another
        # :rejected event and re-schedule. Auto-retry is already armed
        # via Process.send_after by handle_rate_limit_event.
        user_msg = %{role: :user, content: text, timestamp: DateTime.utc_now()}
        {state, user_msg} = append_message(state, user_msg)
        Persistence.persist_message(state, user_msg)
        Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{agent_id: state.id, msg: user_msg})

        wait_s =
          case compute_rate_limit_wait_ms(state.rate_limit_resets_at_ms) do
            n when is_integer(n) -> div(n, 1000)
            _ -> 60
          end

        hold_msg = %{
          role: :system,
          content: "Holding your message — rate-limited, retrying in ~#{wait_s}s.",
          timestamp: DateTime.utc_now()
        }
        {state, hold_msg} = append_message(state, hold_msg)
        Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{agent_id: state.id, msg: hold_msg})
        {:noreply, state}

      state.status == :auth_expired ->
        # No recovery path — the CLI can't reach the API. Record the
        # send attempt so the user sees their message, then surface
        # the same auth-expired error again so they know nothing is
        # going to happen until they re-authenticate.
        user_msg = %{role: :user, content: text, timestamp: DateTime.utc_now()}
        {state, user_msg} = append_message(state, user_msg)
        Persistence.persist_message(state, user_msg)
        Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{agent_id: state.id, msg: user_msg})

        auth_msg = %{
          role: :error,
          content: "Can't send — Claude CLI auth is expired (#{state.auth_error}). Re-auth and restart the agent.",
          timestamp: DateTime.utc_now()
        }
        {state, auth_msg} = append_message(state, auth_msg)
        Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{agent_id: state.id, msg: auth_msg})
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
    state = finalize_partial_on_stream_interrupt(state, state.id, :stopped_by_user)

    if state.session do
      # Stop in a task with timeout — backend.stop can hang if mid-stream.
      # Wrap backend.stop in a Task + Task.yield with timeout so a
      # hung CLI stop doesn't block the GenServer indefinitely. Also
      # wrap in try/catch so a raise inside backend.stop (or a crashed
      # Task) doesn't take down the caller — Task.yield EXITS the
      # caller with the task's exit reason if the task crashes.
      try do
        task = Task.async(fn -> state.backend.stop(state.session) end)
        Task.yield(task, 3_000) || Task.shutdown(task, :brutal_kill)
      catch
        :exit, _ -> :ok
      end
    end

    # Null session so terminate/2's second backend.stop is a no-op —
    # we've already spent our 3s budget here; no need to spend another
    # during terminate.
    stopped = %{state | status: :stopped, session: nil, active_tool: nil}

    # Drop queued pending_sends — user chose to stop; they can
    # resend what matters. Log the count so ops can see if stops
    # are habitually discarding user input (would suggest a UX issue).
    if state.pending_sends != [] do
      BoomLooper.EventLog.info(
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
  def handle_cast(:restart_session, state) do
    # Stop the current session
    if state.session do
      # Wrap backend.stop in a Task + Task.yield with timeout so a
      # hung CLI stop doesn't block the GenServer indefinitely. Also
      # wrap in try/catch so a raise inside backend.stop (or a crashed
      # Task) doesn't take down the caller — Task.yield EXITS the
      # caller with the task's exit reason if the task crashes.
      try do
        task = Task.async(fn -> state.backend.stop(state.session) end)
        Task.yield(task, 3_000) || Task.shutdown(task, :brutal_kill)
      catch
        :exit, _ -> :ok
      end
    end

    # Start a fresh session with the same opts. When we have a Claude
    # session_id captured from prior turns, pass it as `resume:` so the
    # CLI picks up the same conversation.
    case state.backend.start_session(session_opts_with_resume(state)) do
      {:ok, new_session} ->
        state = track_cli_os_pid(%{state | session: new_session, status: :idle})
        :ets.insert(@ets_table, {state.id, summary(state)})
        Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: state.id, status: :idle})

        restart_msg =
          if is_binary(state.claude_session_id) do
            %{role: :system, content: "CLI session restarted (resumed conversation #{String.slice(state.claude_session_id, 0..7)}…)", timestamp: DateTime.utc_now()}
          else
            %{role: :system, content: "CLI session restarted", timestamp: DateTime.utc_now()}
          end
        {state, restart_msg} = append_message(state, restart_msg)
        Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{agent_id: state.id, msg: restart_msg})

        # Fallback when we don't have a CLI session_id yet (e.g. the
        # agent was restarted before its first ResultMessage landed).
        # With a session_id, `resume:` already restored the full
        # conversation — no need to pollute it with a summary prompt.
        if is_nil(state.claude_session_id) do
          resume_msg = build_resume_message(state)
          if resume_msg do
            GenServer.cast(self(), {:send_message, resume_msg})
          end
        end

        {:noreply, state}

      {:error, reason} ->
        error_msg = %{
          role: :error,
          content:
            "Failed to restart the CLI session: #{inspect(reason)}. " <>
              "WHY: the Claude Code CLI couldn't be spawned — usually auth, " <>
              "missing `claude` binary, or a bad working directory. " <>
              "CONSEQUENCE: this agent can't accept new messages. " <>
              "ACTION: run `mix boom.rpc 'ClaudeCode.Test.smoke()'` to diagnose, " <>
              "then click Restart in the sidebar. If restart keeps failing, " <>
              "remove the agent and create a new one.",
          timestamp: DateTime.utc_now()
        }

        {state, error_msg} = append_message(state, error_msg)
        state = %{state | errors: state.errors + 1}
        Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{agent_id: state.id, msg: error_msg})
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:append_external_message, msg}, state) do
    {state, msg} = append_message(state, msg)
    :ets.insert(@ets_table, {state.id, summary(state)})
    Persistence.persist_message(state,msg)
    Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{agent_id: state.id, msg: msg})

    # Auto-continue: if agent is idle and receives an external system message,
    # prompt it to evaluate and continue. The agent decides if work is done.
    if state.status == :idle && msg.role == :system do
      GenServer.cast(self(), {:send_message, "Continue."})
    end

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
            [:boom_looper, :agent, :update_message_failed],
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
      Persistence.persist_message_update(state,msg_id, changes)
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:rename, new_name}, state) do
    state = %{state | name: new_name}
    Events.ChatAgent.publish(%Events.ChatAgent.Renamed{id: state.id, name: new_name})
    {:noreply, state}
  end

  # Catchall for unknown casts. Without this, any bogus cast would
  # crash the GenServer (FunctionClauseError propagates from a
  # non-matching handle_cast/2). audit-2 already closed this gap for
  # handle_info; this closes it for handle_cast. Emits the same
  # `:unknown_message` telemetry so ops visibility is consistent.
  def handle_cast(msg, state) do
    Logger.warning("[ChatAgent] #{state.id} unhandled cast: #{inspect(msg, limit: 200)}")

    :telemetry.execute(
      [:boom_looper, :actor, :unknown_message],
      %{count: 1},
      %{actor: __MODULE__, agent_id: state.id, kind: :cast, msg: inspect(msg, limit: 200)}
    )

    {:noreply, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, summary(state), state}
  end

  # Catchall for unknown calls. Returns an error reply instead of
  # crashing — callers get `{:error, :unknown_call}` they can handle,
  # not a noproc/timeout. Same telemetry as handle_info / handle_cast
  # catchalls.
  def handle_call(msg, _from, state) do
    Logger.warning("[ChatAgent] #{state.id} unhandled call: #{inspect(msg, limit: 200)}")

    :telemetry.execute(
      [:boom_looper, :actor, :unknown_message],
      %{count: 1},
      %{actor: __MODULE__, agent_id: state.id, kind: :call, msg: inspect(msg, limit: 200)}
    )

    {:reply, {:error, :unknown_call}, state}
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
    now = DateTime.utc_now()

    state =
      case event do
        %Event.Text{text: content} ->
          assistant_msg = %{role: :assistant, content: content, timestamp: now}
          {state, assistant_msg} = append_message(state, assistant_msg)
          # Full text arrived — clear any accumulated partial so a
          # subsequent stream_error/timeout doesn't re-emit it.
          state = %{state | last_activity_at: now, in_flight_partial: ""}
          Persistence.persist_message(state,assistant_msg)
          Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{agent_id: id, msg: assistant_msg})
          state

        %Event.ToolCall{name: tool_name, input: tool_input} ->
          tool_msg = %{role: :tool, tool: tool_name, input: tool_input, timestamp: now}
          {state, tool_msg} = append_message(state, tool_msg)

          state = %{state |
            last_activity_at: now,
            tool_calls: state.tool_calls + 1,
            active_tool: tool_name,
            tool_calls_this_turn: state.tool_calls_this_turn + 1
          }

          # Loop detection: same tool + same input N times in a row
          # almost always means the agent is stuck grinding. Fingerprint
          # the call + count consecutive repeats. At threshold, append
          # a visible warning so the user knows they can interrupt
          # instead of watching the tokens burn.
          state = maybe_detect_tool_loop(state, id, tool_name, tool_input)

          # Runaway cap: even if individual calls differ, a 50+ tool-call
          # turn is almost always the agent flailing. Warn once.
          state = maybe_detect_tool_runaway(state, id)

          Persistence.persist_message(state, tool_msg)
          Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{agent_id: id, msg: tool_msg})
          state

        %Event.ToolResult{content: content, is_error: is_error} ->
          result_msg = %{role: :tool_result, content: content, is_error: is_error, timestamp: now}
          {state, result_msg} = append_message(state, result_msg)
          state = %{state | last_activity_at: now, active_tool: nil}
          Persistence.persist_message(state, result_msg)
          Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{agent_id: id, msg: result_msg})
          state

        %Event.TextDelta{text: text} ->
          # Accumulate deltas so stream-error / stream-timeout can
          # finalize a partial-text message. The UI still renders the
          # live stream via the broadcast — accumulator is ONLY for
          # the truncation-recovery path. See agent-sanity #3.
          Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.TextDelta{agent_id: id, text: text})
          %{state | in_flight_partial: state.in_flight_partial <> (text || "")}

        %Event.SessionResult{} = result ->
          # Accumulate token usage across turns. Persist after ETS
          # insert — without this, tokens live only in RAM, and a
          # server restart replays the original :agent record (frozen
          # at init_fresh) so the Claude panel zeroes out.
          #
          # Also harvest the Claude CLI's session_id here. The SDK
          # Session GenServer captures it internally from each result
          # message; we mirror it onto ChatAgent state so server
          # restart / CLI crash / auto-reconnect can pass it back as
          # `resume:` and continue the same conversation instead of
          # waking up amnesiac.
          claude_sid = state.backend.session_id(state.session) || state.claude_session_id

          # Context-window utilization. `input_tokens` is what Claude
          # was sent THIS turn (cumulative conversation context, since
          # we don't prune). Dividing by the model's window size gives
          # us a live % full — when it climbs toward 1.0 the CLI will
          # silently start dropping earliest turns. See agent-sanity #18.
          window = context_window_for(result.model || state.model)
          utilization =
            if window > 0 do
              (result.input_tokens + result.cache_read_tokens) / window
            else
              state.context_utilization
            end

          state = %{state |
            model: result.model || state.model,
            total_input_tokens: state.total_input_tokens + result.input_tokens,
            total_output_tokens: state.total_output_tokens + result.output_tokens,
            total_cache_read_tokens: state.total_cache_read_tokens + result.cache_read_tokens,
            total_cost_usd: state.total_cost_usd + result.cost_usd,
            claude_session_id: claude_sid,
            context_utilization: utilization
          }

          state = maybe_warn_context_full(state, id, utilization)

          :ets.insert(@ets_table, {id, summary(state)})
          Persistence.persist_agent(state, &summary/1)
          Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: id, status: state.status})
          state

        %Event.RateLimitStatus{} = rl ->
          handle_rate_limit_event(state, rl)

        %Event.AuthStatus{} = auth ->
          handle_auth_status_event(state, auth)

        _ ->
          state
      end

    {:noreply, state}
  end

  # Stale stream event — ref doesn't match the current stream. The Task
  # that emitted this belongs to a previous session that was replaced
  # (CLI crash, user restart, retry). Drop it; applying to current state
  # would corrupt the next turn's messages/tokens.
  def handle_info({:stream_event, _id, _ref, _event}, state) do
    :telemetry.execute(
      [:boom_looper, :agent, :stale_stream_event],
      %{count: 1},
      %{agent_id: state.id}
    )
    {:noreply, state}
  end

  @impl true
  def handle_info({:stream_done, id, ref}, %{id: id, stream_ref: ref} = state) do
    # Turn counter and transient tool/ref are part of summary — without
    # ETS sync + persist here, UI reads stale data and restart replay
    # loses the increment.
    # Clear in_flight_partial on clean stream_done — by now either an
    # Event.Text already finalized the assistant response, or the turn
    # ended with only tool calls. Either way, there's no orphan partial.
    state = %{state |
      status: :idle,
      active_tool: nil,
      turns: state.turns + 1,
      in_flight_partial: "",
      context_warning_sent: false,
      # Reset loop-detection counter at turn boundaries. A new turn is
      # a natural reset point — if the agent is truly still looping in
      # the next turn it'll hit the threshold again and re-warn.
      last_tool_call: nil,
      tool_calls_this_turn: 0,
      tool_runaway_warned: false
    }
    state = Map.put(state, :consecutive_crashes, 0)
    state = schedule_idle_check(state)
    :ets.insert(@ets_table, {id, summary(state)})
    Persistence.persist_agent(state, &summary/1)
    Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: id, status: :idle})
    drain_pending_sends(state)
  end

  # Stale stream_done — belongs to a replaced stream, ignore.
  def handle_info({:stream_done, _id, _ref}, state), do: {:noreply, state}

  @impl true
  def handle_info({:stream_timeout, id, ref}, %{id: id, status: :thinking, stream_ref: ref} = state) do
    # Still thinking after timeout AND ref matches current stream — the streaming task is gone
    BoomLooper.EventLog.warning("agent:#{state.name}", "Stream timed out, resetting to idle")

    # Finalize any partial text the stream produced before the timeout
    # so users don't lose it on browser refresh. See agent-sanity #3.
    state = finalize_partial_on_stream_interrupt(state, id, :timeout)

    error_msg = %{
      role: :error,
      content:
        "Agent stopped responding after 10 minutes. " <>
          "WHY: the streaming task produced no events within the timeout window — usually a tool " <>
          "call (exec, rebuild, compose up) hung, or the CLI deadlocked. " <>
          "CONSEQUENCE: the turn was dropped; any partial assistant text was preserved. " <>
          "ACTION: send another message to retry. If the same tool keeps wedging, check " <>
          "/system/events for the tool name and diagnose it in isolation.",
      timestamp: DateTime.utc_now()
    }
    {state, error_msg} = append_message(state, error_msg)
    # Clear active_tool — if the stream timed out with a tool in flight
    # the tool call is orphaned and the UI spinner would stick forever.
    state = %{state | status: :idle, active_tool: nil, errors: state.errors + 1}
    Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{agent_id: id, msg: error_msg})
    Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: id, status: :idle})
    drain_pending_sends(state)
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
    BoomLooper.EventLog.error("agent:#{state.name}", "Stream error: #{reason}")
    now = DateTime.utc_now()

    # Finalize any partial assistant text so the user doesn't lose it
    # on browser refresh. See agent-sanity #3.
    state = finalize_partial_on_stream_interrupt(state, id, :error)

    # Count recent crashes (within last 60 seconds)
    recent_crashes = state.messages
      |> Enum.filter(fn m -> m.role == :system && m.content == "Agent crashed — restarting..." &&
         DateTime.diff(now, m.timestamp, :second) < 60 end)
      |> length()

    if is_binary(reason) && String.contains?(reason, "CLI session exited") && recent_crashes < 2 do
      # CLI died — restart session and resume the same conversation
      # when we have a captured session_id. Without resume, this was
      # an amnesia event: the new CLI had the system prompt only and
      # acted like a brand-new agent even though the user could still
      # see the full message history in the sidebar.
      state = %{state | last_activity_at: now, errors: state.errors + 1}

      case state.backend.start_session(session_opts_with_resume(state)) do
        {:ok, new_session} ->
          recovered_msg =
            if is_binary(state.claude_session_id) do
              %{role: :system, content: "Agent session restarted automatically (resumed conversation #{String.slice(state.claude_session_id, 0..7)}…).", timestamp: DateTime.utc_now()}
            else
              %{role: :system, content: "Agent session restarted automatically.", timestamp: DateTime.utc_now()}
            end
          # active_tool: nil — the old session died mid-tool-call; the new
          # session has no idea that tool was in flight, and leaving the
          # field set would pin a spinner to the UI forever.
          {state, recovered_msg} = append_message(track_cli_os_pid(%{state | session: new_session, status: :idle, active_tool: nil}), recovered_msg)
          Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{agent_id: id, msg: recovered_msg})
          Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: id, status: :idle})

          # Fallback: only send a synthetic resume prompt if we had no
          # session_id to `resume:` with (e.g. CLI died before the very
          # first ResultMessage). See restart_session cast for the same
          # guard.
          if is_nil(state.claude_session_id) do
            resume_msg = build_resume_message(state)
            if resume_msg do
              GenServer.cast(self(), {:send_message, resume_msg})
            end
          end

          drain_pending_sends(state)

        {:error, reason} ->
          fail_msg = %{
            role: :error,
            content:
              "CLI session crashed and failed to restart: #{inspect(reason)}. " <>
                "WHY: the CLI died mid-stream, and the second attempt to spawn a new one failed. " <>
                "CONSEQUENCE: this agent can't respond until the CLI is restored. " <>
                "ACTION: click Restart in the sidebar. If that also fails, the Claude CLI " <>
                "may be misconfigured — verify `claude --version` and re-authenticate.",
            timestamp: DateTime.utc_now()
          }

          {state, fail_msg} = append_message(state, fail_msg)
          state = %{state | status: :idle, active_tool: nil}
          Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{agent_id: id, msg: fail_msg})
          Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: id, status: :idle})
          drain_pending_sends(state)
      end
    else
      error_msg = %{
        role: :error,
        content:
          "Stream error: #{reason}. " <>
            "WHY: the CLI reported an unrecoverable error mid-stream (common: MCP tool " <>
            "crash, payload too big, malformed tool response). " <>
            "CONSEQUENCE: the in-flight turn was dropped. Prior context is preserved. " <>
            "ACTION: send another message — the agent will retry. If the same error " <>
            "recurs, check /system/events for details.",
        timestamp: now
      }

      {state, error_msg} = append_message(state, error_msg)
      state = %{state | status: :idle, active_tool: nil, last_activity_at: now, errors: state.errors + 1}
      Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{agent_id: id, msg: error_msg})
      Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: id, status: :idle})
      drain_pending_sends(state)
    end
  end

  # Linked streaming task died — auto-restart session with backoff.
  # Without backoff, a deterministic crash (e.g. tools/list serialization
  # bug) creates a hot restart loop that hammers the Claude API until
  # rate-limited.
  # Idle-reap defaults. Overridable via app env:
  #   :agent_idle_reap_hours (default 4) — how long an idle agent
  #     holds its Claude CLI subprocess before we stop it.
  #   :agent_idle_check_interval_ms (default 600_000 = 10 min) —
  #     how often the agent runs the idle-check tick.
  #
  # Kept as a function (not a module attribute) so test suites can
  # override per-test without restarting the compiler.
  @default_agent_idle_reap_hours 4
  @default_agent_idle_check_interval_ms 600_000

  @max_consecutive_crashes 5
  # Configurable via Application env for tests:
  #   Application.put_env(:boom_looper, :crash_backoff_base_ms, 0)
  @default_crash_backoff_base_ms 2_000

  @impl true
  def handle_info({:EXIT, _pid, reason}, %{status: :thinking} = state) when reason != :normal do
    BoomLooper.EventLog.warning("agent:#{state.name}", "Streaming task died: #{inspect(reason)}")
    id = state.id
    consecutive = Map.get(state, :consecutive_crashes, 0) + 1

    if consecutive > @max_consecutive_crashes do
      error_msg = %{
        role: :error,
        content:
          "Agent crashed #{consecutive} times in a row — giving up to protect the Claude API from hot-loop retries. " <>
            "WHY: the streaming task kept dying within the exponential-backoff window. Most common cause: " <>
            "a repeatable bug in a tool the agent keeps calling. " <>
            "CONSEQUENCE: this agent is now :crashed and won't auto-retry. Prior conversation is preserved. " <>
            "ACTION: (1) check /system/quarantine + /system/events for the crash reason, " <>
            "(2) fix the underlying issue (if it's a tool, run `mix test` on it), " <>
            "(3) click Restart in the sidebar to resume the conversation.",
        timestamp: DateTime.utc_now()
      }

      {state, error_msg} = append_message(state, error_msg)
      state = %{state | status: :crashed, active_tool: nil, errors: state.errors + 1}
      state = Map.put(state, :consecutive_crashes, consecutive)
      Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{agent_id: id, msg: error_msg})
      Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: id, status: :crashed})
      {:noreply, state}
    else
      # Exponential backoff scheduled via `Process.send_after` — NOT
      # synchronous sleep. Audit-2 HIGH #2 note: we stash the dead
      # session pid in state.retry_from_session so :retry_session
      # can verify no one else (e.g. ensure_session_alive racing via
      # a user's send_message) replaced state.session during the
      # backoff. Without that guard, both paths would spawn a new
      # session and orphan one CLI process per race.
      #
      # Audit-2 LOW #7: transition status to :backoff and broadcast
      # so the UI stops claiming "thinking" during the (up to 32s)
      # backoff window. :retry_session flips back to :idle on
      # success or :crashed on failure.
      base = Application.get_env(:boom_looper, :crash_backoff_base_ms, @default_crash_backoff_base_ms)
      backoff_ms = BoomLooper.Retry.backoff_ms(consecutive, {:exponential, base})
      BoomLooper.EventLog.info("agent:#{state.name}", "Backing off #{backoff_ms}ms before restart (crash ##{consecutive})")
      Process.send_after(self(), {:retry_session, consecutive, state.session}, backoff_ms)
      state = %{state | status: :backoff, active_tool: nil}
      state = Map.put(state, :consecutive_crashes, consecutive)
      state = Map.put(state, :retry_from_session, state.session)
      :ets.insert(@ets_table, {id, summary(state)})
      Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: id, status: :backoff})
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
    id = state.id

    cond do
      state.session != dead_session and state.session != nil ->
        # Another path already replaced the session. No-op; the new
        # session is owned by whoever replaced it.
        BoomLooper.EventLog.info(
          "agent:#{state.name}",
          "Skipped scheduled :retry_session (session already replaced by another path)"
        )

        state = Map.delete(state, :retry_from_session)
        {:noreply, state}

      true ->
        dispatch_retry_session(state, id, consecutive)
    end
  end

  # Legacy 2-tuple form (older scheduled messages from before the
  # dead_session guard landed). Treat as a forced retry.
  @impl true
  def handle_info({:retry_session, consecutive}, state) do
    dispatch_retry_session(state, state.id, consecutive)
  end

  # Fired by handle_rate_limit_event when a :rejected status was seen.
  # We scheduled this for ~`resets_at_ms`. On fire, only flip back to
  # idle if the agent is still in :rate_limited (another path may have
  # moved it; don't stomp). Let the user's next send_message actually
  # try the CLI again — if we're still rate-limited, the CLI will
  # emit another :rejected and we'll re-schedule.
  def handle_info({:rate_limit_retry, id}, %{id: id, status: :rate_limited} = state) do
    state = %{state |
      status: :idle,
      rate_limit_status: :ok,
      rate_limit_resets_at_ms: nil
    }
    :ets.insert(@ets_table, {id, summary(state)})
    Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: id, status: :idle})

    resumed_msg = %{
      role: :system,
      content: "Rate-limit window cleared. Send a message to continue.",
      timestamp: DateTime.utc_now()
    }
    {state, resumed_msg} = append_message(state, resumed_msg)
    Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{agent_id: id, msg: resumed_msg})

    drain_pending_sends(state)
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
    state =
      if reap_eligible?(state) do
        BoomLooper.EventLog.info(
          "agent:#{state.name}",
          "Reaping idle CLI subprocess (idle #{DateTime.diff(DateTime.utc_now(), state.last_activity_at, :second)}s, claude_session_id=#{String.slice(state.claude_session_id, 0..7)}…)"
        )

        :telemetry.execute(
          [:boom_looper, :agent, :idle_reaped],
          %{idle_seconds: DateTime.diff(DateTime.utc_now(), state.last_activity_at, :second)},
          %{agent_id: state.id}
        )

        # Graceful CLI stop with a short cap — don't let a wedged CLI
        # block the reaper tick.
        if state.session && state.backend do
          task = Task.async(fn -> state.backend.stop(state.session) end)
          Task.yield(task, 3_000) || Task.shutdown(task, :brutal_kill)
        end

        # Release the tracked OS pid so the Janitor drops its
        # reference. A second safety-kill by Resources.release isn't
        # needed — backend.stop already ended the process — but
        # clearing the entry keeps /system/orphans accurate.
        if state.tracked_cli_os_pid do
          BoomLooper.Resources.release(:claude_cli, state.tracked_cli_os_pid)
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
          [:boom_looper, :agent, :mailbox_pressure],
          %{message_queue_len: n},
          %{agent_id: state.id}
        )

        BoomLooper.EventLog.warning(
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
    state = schedule_idle_check(state)
    {:noreply, state}
  end

  # Normal-reason EXITs from linked streaming Tasks: happen on every
  # successful turn when the stream Task's closure returns. trap_exit
  # converts these to messages. Without this explicit clause they
  # fell through to the unknown-message catch-all below, spamming
  # warning logs + telemetry on every stream. See audit-2 HIGH #1.
  def handle_info({:EXIT, _pid, :normal}, state), do: {:noreply, state}

  def handle_info(msg, state) do
    Logger.warning("[ChatAgent] #{state.id} unhandled message: #{inspect(msg, limit: 200)}")

    :telemetry.execute(
      [:boom_looper, :actor, :unknown_message],
      %{count: 1},
      %{actor: __MODULE__, agent_id: state.id, msg: inspect(msg, limit: 200)}
    )

    {:noreply, state}
  end

  # --- Private: session retry ---

  defp dispatch_retry_session(state, id, consecutive) do
    case state.backend.start_session(session_opts_with_resume(state)) do
      {:ok, new_session} ->
        content =
          if is_binary(state.claude_session_id) do
            "Session crashed — restarted automatically (attempt #{consecutive}, resumed conversation #{String.slice(state.claude_session_id, 0..7)}…)."
          else
            "Session crashed — restarted automatically (attempt #{consecutive})."
          end

        recovered_msg = %{
          role: :system,
          content: content,
          timestamp: DateTime.utc_now()
        }

        {state, recovered_msg} =
          append_message(
            track_cli_os_pid(%{state | session: new_session, status: :idle, active_tool: nil, errors: state.errors + 1}),
            recovered_msg
          )

        state = Map.put(state, :consecutive_crashes, consecutive)
        state = Map.delete(state, :retry_from_session)
        Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{agent_id: id, msg: recovered_msg})
        Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: id, status: :idle})
        {:noreply, state}

      {:error, reason} ->
        error_msg = %{
          role: :error,
          content:
            "Session retry ##{consecutive} failed: #{inspect(reason)}. " <>
              "WHY: exponential backoff expired; the attempt to re-spawn the Claude CLI errored. " <>
              "CONSEQUENCE: the agent is idle but the CLI isn't running. Your prior messages are preserved. " <>
              "ACTION: send another message — this triggers ensure_session_alive which will " <>
              "retry the spawn. If it keeps failing, check `claude --version` + auth, or " <>
              "click Restart. After #{@max_consecutive_crashes} consecutive failures the " <>
              "agent will auto-quarantine until you intervene.",
          timestamp: DateTime.utc_now()
        }

        {state, error_msg} = append_message(state, error_msg)
        state = %{state | status: :idle, active_tool: nil, errors: state.errors + 1}
        state = Map.put(state, :consecutive_crashes, consecutive)
        state = Map.delete(state, :retry_from_session)
        Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{agent_id: id, msg: error_msg})
        Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: id, status: :idle})
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    # Always TRY a clean shutdown of the SDK session — a graceful
    # protocol exit is preferable to a SIGKILL and lets the CLI flush
    # any pending writes. Cap at 3s so we never block the supervisor.
    if state.session && state.backend do
      try do
        task = Task.async(fn -> state.backend.stop(state.session) end)
        Task.yield(task, 3_000) || Task.shutdown(task, :brutal_kill)
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end

    # We do NOT manually SIGKILL the CLI OS process here. It's tracked
    # via BoomLooper.Resources.track(:claude_cli, os_pid) so the Janitor
    # receives our DOWN message (sent on any exit reason, including
    # :normal) and runs the release fn — SIGKILL if still alive, no-op
    # if the clean shutdown above already ended it. This also covers
    # the paths where `terminate/2` never runs (brutal_kill, node
    # crash, :shutdown-timeout exceeded) — the main reason surface #12
    # exists.

    unless state.status in [:stopped, :destroying] do
      crashed = %{state | status: :crashed}
      :ets.insert(@ets_table, {state.id, summary(crashed)})
      Events.ChatAgent.publish(%Events.ChatAgent.Stopped{summary: summary(crashed)})
    end
  end

  # --- Private ---

  defp build_resume_message(state) do
    # Build a compact summary of recent activity so the new session can continue
    recent = state.messages |> Enum.take(20) |> Enum.reverse()
    return_nothing = length(recent) < 3

    if return_nothing do
      nil
    else
      # Summarize what tools were used and what the last assistant message said
      tool_names = recent
        |> Enum.filter(&(&1.role == :tool))
        |> Enum.map(&(&1[:tool]))
        |> Enum.uniq()

      last_assistant = recent
        |> Enum.filter(&(&1.role == :assistant))
        |> List.last()

      last_system = recent
        |> Enum.filter(&(&1.role in [:system, :build_done]))
        |> List.last()

      parts = ["Your session crashed and was restarted. Here's what was happening:"]

      parts = if tool_names != [] do
        parts ++ ["Recent tools used: #{Enum.join(tool_names, ", ")}"]
      else
        parts
      end

      parts = if last_assistant do
        parts ++ ["Your last message: #{String.slice(last_assistant.content, 0..500)}"]
      else
        parts
      end

      parts = if last_system do
        parts ++ ["Last system status: #{String.slice(last_system.content, 0..500)}"]
      else
        parts
      end

      parts = parts ++ ["Continue where you left off. If you were setting up the dev environment, check service_status and follow the verification loop."]

      Enum.join(parts, "\n\n")
    end
  end

  defp load_workspace_config(workspace_id) when is_binary(workspace_id) do
    volume_name = BoomLooper.Workspace.volume_name_for(workspace_id)
    case BoomLooper.Workspace.load_from_volume(volume_name) do
      {:ok, workspace} -> workspace
      _ -> nil
    end
  end

  # Ensure whatever session_opts we hand to the backend carry the
  # latest Claude CLI session_id as `resume:`. This is what makes a
  # respawned CLI continue the same conversation instead of booting
  # fresh. Called on every code path that restarts the session —
  # :restart_session cast, crash-recovery, retry-after-backoff,
  # ensure_session_alive.
  # The normal (non-rate-limited, non-auth-expired) path of
  # handle_cast({:send_message, text}). Kept as a defp so the cast
  # clauses stay contiguous (Elixir warns on non-grouped clauses) and
  # the cond in send_message stays readable.
  defp send_message_normal(state, text) do
    state = ensure_session_alive(state)

    user_msg = %{role: :user, content: text, timestamp: DateTime.utc_now()}
    {state, user_msg} = append_message(state, user_msg)
    Persistence.persist_message(state, user_msg)
    Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{agent_id: state.id, msg: user_msg})

    if not state.backend.session_alive?(state.session) do
      Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: state.id, status: :idle})
      {:noreply, state}
    else
      state = %{state | status: :thinking}
      Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: state.id, status: :thinking})

      # Generate stream_ref BEFORE spawning the Task so every event the
      # Task emits is tagged with the ref that identifies THIS stream.
      # When the session is replaced mid-stream (CLI crash retry, user
      # restart), the handler on the other side uses the ref to drop
      # stale events from the dead stream — otherwise they'd land on
      # the new state and corrupt the next turn. See agent-sanity #16.
      stream_ref = make_ref()
      me = self()
      agent_id = state.id
      session = state.session
      backend = state.backend

      Task.start_link(fn ->
        try do
          backend.stream(session, text)
          |> Enum.each(fn event ->
            send(me, {:stream_event, agent_id, stream_ref, event})
          end)

          send(me, {:stream_done, agent_id, stream_ref})
        rescue
          e ->
            send(me, {:stream_error, agent_id, stream_ref, Exception.message(e)})
        catch
          :exit, reason ->
            send(me, {:stream_error, agent_id, stream_ref, "CLI session exited: #{inspect(reason)}"})
        end
      end)

      Process.send_after(self(), {:stream_timeout, agent_id, stream_ref}, 600_000)

      # Clear in_flight_partial — any prior partial was already
      # finalized on the prior turn's stream_done/error. New stream,
      # new accumulator.
      {:noreply, %{state | stream_ref: stream_ref, in_flight_partial: ""}}
    end
  end

  # Handle a %Event.RateLimitStatus{} from the Claude CLI.
  #
  # `:allowed`         — normal traffic. Clear any lingering rate-limit
  #                       state. If we were previously :rate_limited, flip
  #                       back to :idle so the user can send again.
  # `:allowed_warning` — we're approaching the cap. Don't change status
  #                       (might be mid-turn), but record the warning so
  #                       the UI can render a subtle "approaching limit"
  #                       indicator.
  # `:rejected`        — the next request WILL fail. Flip status to
  #                       :rate_limited, stash resets_at_ms so the UI
  #                       renders a live countdown, and schedule a
  #                       Process.send_after auto-retry exactly at reset.
  #                       We cap the wait so a poisoned/skewed clock
  #                       doesn't lock the agent up forever.
  #
  # Telemetry: every transition emits
  # `[:boom_looper, :agent, :rate_limit]` so ops can watch the rate of
  # :rejected events. A sustained spike there = the whole account is
  # hitting its plan cap.
  defp handle_rate_limit_event(state, %Event.RateLimitStatus{} = rl) do
    id = state.id

    :telemetry.execute(
      [:boom_looper, :agent, :rate_limit],
      %{count: 1},
      %{agent_id: id, status: rl.status, rate_limit_type: rl.rate_limit_type}
    )

    case rl.status do
      :rejected ->
        # Cap auto-retry wait at 1h — if resets_at is in the past or
        # far-future (clock skew, misparsed epoch), retry in 60s instead
        # of locking the agent forever.
        wait_ms = compute_rate_limit_wait_ms(rl.resets_at_ms)

        BoomLooper.EventLog.warning(
          "agent:#{state.name}",
          "Rate-limited (#{inspect(rl.rate_limit_type)}), retrying in #{div(wait_ms, 1000)}s"
        )

        Process.send_after(self(), {:rate_limit_retry, id}, wait_ms)

        rl_msg = %{
          role: :system,
          content:
            "Rate-limited by Claude API (#{rl.rate_limit_type || "limit"}). " <>
              "Retrying automatically in ~#{div(wait_ms, 1000)}s.",
          timestamp: DateTime.utc_now()
        }

        {state, rl_msg} =
          append_message(
            %{state |
              status: :rate_limited,
              active_tool: nil,
              rate_limit_status: :rejected,
              rate_limit_resets_at_ms: rl.resets_at_ms,
              rate_limit_type: rl.rate_limit_type
            },
            rl_msg
          )

        Persistence.persist_message(state, rl_msg)
        :ets.insert(@ets_table, {id, summary(state)})
        Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{agent_id: id, msg: rl_msg})
        Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: id, status: :rate_limited})
        state

      :allowed_warning ->
        state = %{state |
          rate_limit_status: :warning,
          rate_limit_resets_at_ms: rl.resets_at_ms,
          rate_limit_type: rl.rate_limit_type
        }
        :ets.insert(@ets_table, {id, summary(state)})
        # No status broadcast — main status stays :thinking mid-turn. The
        # summary delta (rate_limit_status: :warning) flows to any viewer
        # that's reading the agent record.
        state

      :allowed ->
        # Transition out of rate-limited state, if we were in one.
        was_rate_limited = state.rate_limit_status != :ok
        new_main_status = if state.status == :rate_limited, do: :idle, else: state.status

        state = %{state |
          status: new_main_status,
          rate_limit_status: :ok,
          rate_limit_resets_at_ms: nil,
          rate_limit_type: nil
        }
        :ets.insert(@ets_table, {id, summary(state)})
        if was_rate_limited do
          Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: id, status: new_main_status})
        end
        state

      _other ->
        state
    end
  end

  defp compute_rate_limit_wait_ms(resets_at_ms) when is_integer(resets_at_ms) do
    now_ms = System.system_time(:millisecond)
    delta = resets_at_ms - now_ms
    cond do
      delta <= 0 -> 60_000
      delta > 3_600_000 -> 60_000
      true -> delta + 1_000
    end
  end
  defp compute_rate_limit_wait_ms(_), do: 60_000

  # Handle a %Event.AuthStatus{} from the Claude CLI.
  #
  # is_authenticating=true with error=nil is routine (OAuth flow running).
  # Any non-nil error is terminal — the CLI can't talk to the API without
  # working creds, and we don't know how to fix them automatically. Flip
  # to :auth_expired, surface the error in the chat, and stop retrying.
  # The user has to re-authenticate (outside BoomLooper today).
  defp handle_auth_status_event(state, %Event.AuthStatus{error: nil, is_authenticating: true}) do
    # Auth in progress — not an error. No state change.
    state
  end

  defp handle_auth_status_event(state, %Event.AuthStatus{error: error}) when is_binary(error) do
    id = state.id

    :telemetry.execute(
      [:boom_looper, :agent, :auth_expired],
      %{count: 1},
      %{agent_id: id, error: error}
    )

    BoomLooper.EventLog.error("agent:#{state.name}", "Claude auth failed: #{error}")

    auth_msg = %{
      role: :error,
      content: "Claude authentication failed: #{error}. Re-authenticate the CLI and restart this agent.",
      timestamp: DateTime.utc_now()
    }

    {state, auth_msg} =
      append_message(
        %{state | status: :auth_expired, active_tool: nil, auth_error: error, errors: state.errors + 1},
        auth_msg
      )

    Persistence.persist_message(state, auth_msg)
    :ets.insert(@ets_table, {id, summary(state)})
    Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{agent_id: id, msg: auth_msg})
    Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: id, status: :auth_expired})
    state
  end

  defp handle_auth_status_event(state, _other), do: state

  # If a stream is cut short (error / timeout / CLI exit) with partial
  # text accumulated from TextDelta events, finalize it as an assistant
  # message with a truncation marker so the user sees their half-answer
  # preserved in the transcript. Without this, the UI shows the partial
  # text live via PubSub, then it vanishes on refresh because nothing
  # was persisted. See agent-sanity #3.
  #
  # `reason` is `:error | :timeout` — included in the marker so the
  # user can distinguish "CLI crashed" from "took too long."
  defp finalize_partial_on_stream_interrupt(%{in_flight_partial: ""} = state, _id, _reason), do: state

  defp finalize_partial_on_stream_interrupt(%{in_flight_partial: partial} = state, id, reason)
       when is_binary(partial) and partial != "" do
    marker =
      case reason do
        :error -> "⚠ Truncated — CLI stream errored mid-response."
        :timeout -> "⚠ Truncated — CLI stopped responding mid-stream."
        :stopped_by_user -> "⚠ Truncated — user stopped the agent mid-response."
        other -> "⚠ Truncated — stream ended unexpectedly (#{inspect(other)})."
      end

    partial_msg = %{
      role: :assistant,
      content: partial <> "\n\n" <> marker,
      partial: true,
      timestamp: DateTime.utc_now()
    }

    {state, partial_msg} = append_message(state, partial_msg)
    Persistence.persist_message(state, partial_msg)
    Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{agent_id: id, msg: partial_msg})

    :telemetry.execute(
      [:boom_looper, :agent, :partial_finalized],
      %{bytes: byte_size(partial)},
      %{agent_id: id, reason: reason}
    )

    %{state | in_flight_partial: ""}
  end

  defp finalize_partial_on_stream_interrupt(state, _id, _reason), do: state

  # Track the Claude CLI subprocess OS pid under this ChatAgent via
  # BoomLooper.Resources. On our DOWN (brutal_kill, node crash,
  # :shutdown-timeout), the Janitor SIGKILLs the OS pid — covering the
  # paths where `terminate/2` never runs. Releases any previously
  # tracked pid before tracking the new one so state.tracked_cli_os_pid
  # stays consistent with state.session.
  #
  # Returns {:ok, state} with state.tracked_cli_os_pid updated. If we
  # can't find the OS pid (session dead, Port not yet up, dep internals
  # changed), we skip tracking and clear any stale tracked pid — losing
  # one OS-level safety net is not worth crashing the GenServer over.
  defp track_cli_os_pid(state) do
    # Release stale tracking — previous session's OS pid is no longer
    # ours, and re-tracking by kind+id would fail under a new owner.
    if state.tracked_cli_os_pid do
      BoomLooper.Resources.release(:claude_cli, state.tracked_cli_os_pid)
    end

    case state.session && state.backend && BoomLooper.ChatAgent.OSProcess.pid_of(state.session) do
      os_pid when is_integer(os_pid) ->
        release_fn = fn -> BoomLooper.ChatAgent.OSProcess.kill(os_pid) end

        case BoomLooper.Resources.track(self(), :claude_cli, os_pid, release_fn) do
          :ok ->
            %{state | tracked_cli_os_pid: os_pid}

          {:error, :already_tracked} ->
            # Some other owner already tracks this OS pid. Rare — usually
            # means our previous release/3 raced with someone else picking
            # it up. Keep state consistent but don't stomp.
            %{state | tracked_cli_os_pid: nil}
        end

      _ ->
        %{state | tracked_cli_os_pid: nil}
    end
  end

  # Runaway detection: count tool calls per turn (any tool, any
  # input). One-shot warning at @turn_tool_limit so the user knows
  # to stop the agent if it's thrashing. Different from
  # maybe_detect_tool_loop which catches same-tool+same-input
  # repeats — this catches agents that call 50 different things in
  # a row without making progress.
  defp maybe_detect_tool_runaway(%{tool_runaway_warned: true} = state, _id), do: state

  defp maybe_detect_tool_runaway(%{tool_calls_this_turn: n} = state, id)
       when n >= @turn_tool_limit do
    :telemetry.execute(
      [:boom_looper, :agent, :tool_runaway],
      %{tool_calls_this_turn: n},
      %{agent_id: id}
    )

    BoomLooper.EventLog.warning(
      "agent:#{state.name}",
      "Tool-call runaway — #{n} tool calls in a single turn"
    )

    warn_msg = %{
      role: :system,
      content:
        "⚠ Agent has made #{n} tool calls in this single turn. " <>
          "WHY: that's far past the usual 5–20 — either it's stuck exploring or it's " <>
          "looping with slightly-different inputs each time. " <>
          "CONSEQUENCE: every tool call costs tokens and time. If the agent isn't making " <>
          "visible progress, it's wasting both. " <>
          "ACTION: click Stop to interrupt. Give the agent a more specific hint " <>
          "(e.g. 'the file is in lib/foo.ex') and restart.",
      timestamp: DateTime.utc_now()
    }

    {state, warn_msg} = append_message(state, warn_msg)
    Persistence.persist_message(state, warn_msg)
    Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{agent_id: id, msg: warn_msg})
    %{state | tool_runaway_warned: true}
  end

  defp maybe_detect_tool_runaway(state, _id), do: state

  # --- Tool-call loop detection ---

  # Fingerprint a tool call so we can count consecutive repeats.
  # Hash is short (16 hex chars) because we only need equality, not
  # reversibility.
  defp tool_call_hash(tool_name, tool_input) do
    raw = :erlang.term_to_binary({tool_name, tool_input})
    :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower) |> binary_part(0, 16)
  end

  # Update state.last_tool_call based on the current call. If this is
  # the same tool+input as the previous call, bump the counter and —
  # once we cross @tool_loop_threshold — append a one-shot warning so
  # the user can interrupt before more tokens burn. Different tool
  # resets the counter to 1.
  defp maybe_detect_tool_loop(state, id, tool_name, tool_input) do
    hash = tool_call_hash(tool_name, tool_input)

    {new_count, warn?} =
      case state.last_tool_call do
        {^hash, count} when count + 1 == @tool_loop_threshold ->
          # Crossed the threshold THIS call — fire warning once.
          {count + 1, true}

        {^hash, count} ->
          # Still looping but already warned (count > threshold) or not
          # yet at threshold. No re-warn.
          {count + 1, false}

        _ ->
          # Different tool/input OR first call. Reset.
          {1, false}
      end

    state = %{state | last_tool_call: {hash, new_count}}

    if warn? do
      :telemetry.execute(
        [:boom_looper, :agent, :tool_loop_detected],
        %{consecutive: new_count},
        %{agent_id: id, tool: tool_name}
      )

      BoomLooper.EventLog.warning(
        "agent:#{state.name}",
        "Tool-call loop — `#{tool_name}` called #{new_count}× with same input"
      )

      warn_msg = %{
        role: :system,
        content:
          "⚠ Agent called `#{tool_name}` #{new_count} times in a row with the same input — " <>
            "it may be stuck in a retry loop. Consider stopping the agent and providing a " <>
            "different hint, or check whether the tool is returning a consistent error.",
        timestamp: DateTime.utc_now()
      }

      {state, warn_msg} = append_message(state, warn_msg)
      Persistence.persist_message(state, warn_msg)
      Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{agent_id: id, msg: warn_msg})
      state
    else
      state
    end
  end

  # --- Context window utilization (agent-sanity #18) ---

  # Published Claude model window sizes. Approximate; a few models
  # support extended context variants but we pick the mainline default
  # so our % estimate is on the conservative side (i.e. if we say 90%
  # full, we're not lying to the user). When we encounter an unknown
  # model name we return 0 to mean "no estimate" — the warn gate
  # short-circuits on 0 so we don't spam warnings against a
  # never-computed ratio.
  @context_windows %{
    "claude-opus-4-7" => 1_000_000,
    "claude-opus-4-7-20250929" => 1_000_000,
    "claude-opus-4-6" => 1_000_000,
    "claude-opus-4-5" => 1_000_000,
    "claude-sonnet-4-6" => 200_000,
    "claude-sonnet-4-5" => 200_000,
    "claude-sonnet-4-5-20250929" => 200_000,
    "claude-haiku-4-5" => 200_000,
    "claude-haiku-4-5-20251001" => 200_000
  }

  defp context_window_for(nil), do: 200_000
  defp context_window_for(model) when is_binary(model) do
    Map.get(@context_windows, model) ||
      Enum.find_value(@context_windows, 0, fn {prefix, size} ->
        if String.starts_with?(model, prefix), do: size
      end)
  end
  defp context_window_for(_), do: 200_000

  @context_warn_threshold 0.85

  # One-shot warning when utilization crosses the threshold. Gated on
  # `context_warning_sent` so we don't spam per-turn. stream_done
  # resets the flag so the warning re-fires if utilization stays high
  # in a later turn.
  defp maybe_warn_context_full(state, id, utilization)
       when utilization >= @context_warn_threshold do
    if state.context_warning_sent do
      state
    else
      pct = round(utilization * 100)

      warn_msg = %{
        role: :system,
        content:
          "⚠ Context window #{pct}% full. Claude will silently drop the earliest turns " <>
            "once the window fills. Consider starting a fresh agent or running /clear " <>
            "if you want to preserve recent context.",
        timestamp: DateTime.utc_now()
      }

      :telemetry.execute(
        [:boom_looper, :agent, :context_warning],
        %{utilization: utilization},
        %{agent_id: id, model: state.model}
      )

      BoomLooper.EventLog.warning(
        "agent:#{state.name}",
        "Context window #{pct}% full (model=#{state.model || "?"})"
      )

      {state, warn_msg} = append_message(state, warn_msg)
      Persistence.persist_message(state, warn_msg)
      Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{agent_id: id, msg: warn_msg})
      %{state | context_warning_sent: true}
    end
  end

  defp maybe_warn_context_full(state, _id, _utilization), do: state

  # Drain the pending-sends queue if there's anything in it.
  # Called from turn-completion handlers (:stream_done /
  # :stream_error / :stream_timeout / :rate_limit_retry). Returns the
  # same `{:noreply, state}` shape the callers already use so we can
  # just return this.
  #
  # Pops ONE message at a time and synchronously calls
  # send_message_normal — that sets status: :thinking and starts the
  # next stream. Remaining pending messages wait for the next
  # stream_done. This preserves strict FIFO ordering: N queued
  # messages produce N sequential turns.
  defp drain_pending_sends(%{pending_sends: []} = state), do: {:noreply, state}

  defp drain_pending_sends(%{pending_sends: [head | rest]} = state) do
    state = %{state | pending_sends: rest}
    send_message_normal(state, head)
  end

  # --- Idle reaper (agent-sanity #20) ---

  # Arms a single :idle_check timer. Cancels any existing timer first
  # so repeated scheduling (e.g. after every activity) doesn't stack.
  # Returns `state` with the new timer ref in :idle_check_timer so
  # subsequent calls can cancel it.
  defp schedule_idle_check(state) do
    if ref = state.idle_check_timer, do: Process.cancel_timer(ref)
    interval = Application.get_env(:boom_looper, :agent_idle_check_interval_ms, @default_agent_idle_check_interval_ms)
    timer = Process.send_after(self(), :idle_check, interval)
    %{state | idle_check_timer: timer}
  end

  # How many seconds of idleness before the CLI gets reaped.
  defp idle_reap_seconds do
    hours = Application.get_env(:boom_looper, :agent_idle_reap_hours, @default_agent_idle_reap_hours)
    hours * 3600
  end

  # The critical invariant: we only reap when we have a captured
  # claude_session_id. Without it, ensure_session_alive can't
  # re-create the SAME conversation — it would spawn a fresh amnesic
  # CLI. Better to hold the RAM than silently drop context.
  defp reap_eligible?(state) do
    state.status == :idle and
      is_pid(state.session) and
      Process.alive?(state.session) and
      is_binary(state.claude_session_id) and
      state.claude_session_id != "" and
      state.last_activity_at != nil and
      DateTime.diff(DateTime.utc_now(), state.last_activity_at, :second) >= idle_reap_seconds()
  end

  defp session_opts_with_resume(state) do
    case state.claude_session_id do
      sid when is_binary(sid) and sid != "" ->
        Keyword.put(state.session_opts, :resume, sid)

      _ ->
        Keyword.delete(state.session_opts, :resume)
    end
  end

  defp ensure_session_alive(state) do
    alive = try do
      state.backend.session_alive?(state.session)
    rescue
      _ -> false
    catch
      :exit, _ -> false
    end

    if alive do
      state
    else
      require Logger
      BoomLooper.EventLog.warning("agent:#{state.name}", "CLI session dead, auto-restarting")

      restart_msg = %{role: :system, content: "Session lost — reconnecting...", timestamp: DateTime.utc_now()}
      {state, restart_msg} = append_message(state, restart_msg)
      Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{agent_id: state.id, msg: restart_msg})

      case state.backend.start_session(session_opts_with_resume(state)) do
        {:ok, new_session} ->
          BoomLooper.EventLog.info("agent:#{state.name}", "CLI session restarted")
          ok_content =
            if is_binary(state.claude_session_id) do
              "Reconnected (resumed conversation #{String.slice(state.claude_session_id, 0..7)}…)."
            else
              "Reconnected."
            end
          ok_msg = %{role: :system, content: ok_content, timestamp: DateTime.utc_now()}
          {state, ok_msg} = append_message(track_cli_os_pid(%{state | session: new_session}), ok_msg)
          Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{agent_id: state.id, msg: ok_msg})
          state

        {:error, reason} ->
          BoomLooper.EventLog.error("agent:#{state.name}", "Failed to restart CLI: #{inspect(reason)}")

          fail_msg = %{
            role: :error,
            content:
              "Failed to reconnect to Claude CLI: #{inspect(reason)}. " <>
                "WHY: the CLI session died, and trying to spawn a new one failed. " <>
                "CONSEQUENCE: your message was saved but won't be processed until the CLI is back. " <>
                "ACTION: (1) check that `claude` is installed and authenticated " <>
                "(`mix boom.rpc 'ClaudeCode.Test.smoke()'`), (2) click Restart in the sidebar, " <>
                "(3) send your message again. Prior conversation context is preserved.",
            timestamp: DateTime.utc_now()
          }

          {state, fail_msg} = append_message(state, fail_msg)
          Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{agent_id: state.id, msg: fail_msg})
          state
      end
    end
  end

  @max_messages 1000

  defp append_message(state, msg) do
    msg = Map.put_new_lazy(msg, :id, fn -> generate_msg_id() end)
    # Store as reverse list for O(1) prepend. Trim to cap.
    reversed = [msg | state.messages]
    reversed = if length(reversed) > @max_messages, do: Enum.take(reversed, @max_messages), else: reversed
    {%{state | messages: reversed}, msg}
  end

  defp generate_msg_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end

  defp via(id), do: {:via, Registry, {BoomLooper.ChatAgentRegistry, id}}

  defp stuck_booting?(%{status: :booting, started_at: %DateTime{} = t}) do
    DateTime.diff(DateTime.utc_now(), t, :second) > @stuck_booting_seconds
  end

  defp stuck_booting?(_), do: false

  defp summary(state) do
    %{
      id: state.id,
      name: state.name,
      working_dir: state.working_dir,
      bind_mount: state.bind_mount,
      workspace_id: state.workspace_id,
      started_at: state.started_at,
      started_by: state.started_by,
      last_activity_at: state.last_activity_at,
      status: state.status,
      messages: Enum.reverse(state.messages),
      tool_calls: state.tool_calls,
      errors: state.errors,
      service_name: state.service_name,
      agent_type: state.agent_type,
      model: state.model,
      total_input_tokens: state.total_input_tokens,
      total_output_tokens: state.total_output_tokens,
      total_cache_read_tokens: state.total_cache_read_tokens,
      total_cost_usd: state.total_cost_usd,
      active_tool: state.active_tool,
      turns: state.turns,
      claude_session_id: state.claude_session_id,
      rate_limit_status: state.rate_limit_status,
      rate_limit_resets_at_ms: state.rate_limit_resets_at_ms,
      rate_limit_type: state.rate_limit_type,
      auth_error: state.auth_error,
      prompt_hash: state.prompt_hash,
      context_utilization: state.context_utilization
    }
  end

  # All broadcast from ChatAgent is done through the typed publisher
  # modules `BoomLooper.Events.ChatAgent` (topic `"chat_agents"`) and
  # `BoomLooper.Events.ChatAgentMessage` (topic `"chat_agent:{id}"`).
  # The CI boundary test enforces that no other code path calls
  # Phoenix.PubSub.broadcast directly.

  # --- Delegated public API ---

  @doc false
  defdelegate build_system_prompt(agent_id, opts), to: Prompt
end
