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

  alias Loopyard.AgentLog

  alias Loopyard.ChatAgent.{
    IdleReaper,
    Initializer,
    Persistence,
    Prompt,
    SessionManager,
    StreamHandler
  }

  alias Loopyard.Events

  defstruct [
    :id,
    :name,
    :session,
    :session_opts,
    :backend,
    :working_dir,
    :bind_mount,
    :workspace_id,
    # The workstation identity this agent boots its home/env from (the one you
    # were operating as when it started). Lets us count agents per identity and,
    # later, find who to refresh when that identity's home changes.
    :workstation_identity,
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
    # via Loopyard.Resources.track/4 so the Janitor kills it on our
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
  @max_message_bytes Application.compile_env(:loopyard, :max_message_bytes, 1_048_576)

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
    case Registry.lookup(Loopyard.ChatAgentRegistry, id) do
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

  @doc """
  Get a page of messages for an agent. Returns `{messages_slice, total_count}`.

  Options:
    * `:limit` — max messages to return (default 50)
    * `:before_id` — load messages before this message ID (for scroll-up pagination)

  Reads directly from ETS (no GenServer call). Messages are in chronological order.
  """
  def get_messages(agent_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    before_id = Keyword.get(opts, :before_id, nil)

    case :ets.lookup(@ets_table, agent_id) do
      [{^agent_id, summary}] ->
        messages = summary.messages
        total = length(messages)

        slice =
          if before_id do
            idx = Enum.find_index(messages, &(&1[:id] == before_id)) || 0
            start = max(0, idx - limit)
            Enum.slice(messages, start, idx - start)
          else
            Enum.take(messages, -limit)
          end

        {slice, total}

      _ ->
        {[], 0}
    end
  end

  @doc "Append a message to an agent's message list (for stream messages created outside the GenServer).
  Goes through the GenServer if alive, falls back to direct ETS write."
  def append_message_ets(agent_id, msg) do
    msg = Map.put_new_lazy(msg, :id, fn -> generate_msg_id() end)

    case Registry.lookup(Loopyard.ChatAgentRegistry, agent_id) do
      [{pid, _}] ->
        GenServer.cast(pid, {:append_external_message, msg})
        msg

      [] ->
        # No GenServer running — direct ETS write
        case :ets.lookup(@ets_table, agent_id) do
          [{^agent_id, summary}] ->
            :ets.insert(@ets_table, {agent_id, %{summary | messages: summary.messages ++ [msg]}})
            msg

          [] ->
            nil
        end
    end
  end

  @doc "Update a message by ID. Goes through GenServer if alive, falls back to direct ETS."
  def update_message(agent_id, msg_id, update_fn) do
    case Registry.lookup(Loopyard.ChatAgentRegistry, agent_id) do
      [{pid, _}] ->
        GenServer.cast(pid, {:update_message, msg_id, update_fn})
        :ok

      [] ->
        case :ets.lookup(@ets_table, agent_id) do
          [{^agent_id, summary}] ->
            try do
              messages =
                Enum.map(summary.messages, fn msg ->
                  if msg[:id] == msg_id, do: update_fn.(msg), else: msg
                end)

              :ets.insert(@ets_table, {agent_id, %{summary | messages: messages}})
              :ok
            rescue
              e ->
                :telemetry.execute(
                  [:loopyard, :agent, :update_message_failed],
                  %{count: 1},
                  %{agent_id: agent_id, msg_id: msg_id, reason: Exception.message(e)}
                )

                :error
            end

          [] ->
            :error
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
    case Registry.lookup(Loopyard.ChatAgentRegistry, id) do
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
        Loopyard.WorkspaceGroup.agent_sup_name(summary[:workspace_id])
      else
        Loopyard.AgentSupervisor
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
        case Loopyard.ChatAgent.StateMachine.transition(summary.status, :destroying) do
          {:ok, :destroying} ->
            destroying = %{summary | status: :destroying}
            :ets.insert(@ets_table, {id, destroying})
            Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: id, status: :destroying})

          {:error, reason} ->
            Loopyard.EventLog.warning(
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

    # Persist removal to agent log so it's not replayed on restart.
    # Wrap the append — disk failure here shouldn't crash remove_agent
    # (caller is typically a LiveView process the user is interacting
    # with). ETS deletion below is authoritative for runtime state;
    # the log record is belt-and-suspenders for replay.
    case :ets.lookup(@ets_table, id) do
      [{^id, summary}] ->
        ws_id = summary[:workspace_id]

        if ws_id do
          path = Persistence.log_path(ws_id)

          try do
            AgentLog.append({:agent_removed, id}, log_path: path, version: 1)
          rescue
            e ->
              Loopyard.EventLog.warning(
                "agent:#{summary[:name] || id}",
                "remove_agent: failed to persist :agent_removed record: #{Exception.message(e)}. " <>
                  "The agent will be removed from ETS; if this BEAM restarts before the log is " <>
                  "writable again, the agent will be replayed back into ETS on boot."
              )
          catch
            kind, reason ->
              Loopyard.EventLog.warning(
                "agent:#{summary[:name] || id}",
                "remove_agent: log append #{kind}: #{inspect(reason)}"
              )
          end
        end

      [] ->
        :ok
    end

    # Hard-stop the live GenServer FIRST so it can't restart and can't re-insert
    # itself into ETS. Deleting the ETS row alone left the process running, and
    # its next summary write resurrected the row — the "removed agent came back"
    # bug. Terminate via the DynamicSupervisor so OTP won't restart it.
    terminate_process(id)

    # Remove from sidebar
    :ets.delete(@ets_table, id)
    Events.ChatAgent.publish(%Events.ChatAgent.Removed{id: id})
  end

  # Terminate an agent's process so a removed agent stays removed. Best-effort:
  # via the workspace's agent supervisor (no restart) when we know the workspace,
  # else a direct stop; never raises.
  defp terminate_process(id) do
    ws_id =
      case :ets.lookup(@ets_table, id) do
        [{^id, summary}] -> summary[:workspace_id]
        _ -> nil
      end

    case Registry.lookup(Loopyard.ChatAgentRegistry, id) do
      [{pid, _}] when is_binary(ws_id) ->
        DynamicSupervisor.terminate_child(Loopyard.WorkspaceGroup.agent_sup_name(ws_id), pid)

      [{pid, _}] ->
        if Process.alive?(pid), do: GenServer.stop(pid, :normal, 3_000)

      [] ->
        :ok
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc "Register an agent as booting in ETS so all viewers can see it"
  def register_booting(id, name, working_dir, opts \\ []) do
    # Go through summary/1 so the booting entry carries every field
    # summary exposes — tokens (0.0), cost, model (nil), turns, etc.
    # Same reason as init_resume: the UI reads these unconditionally
    # and a partial map would surface as KeyError or zeroed values
    # that look real.
    now = DateTime.utc_now()

    # Populate workspace_id so the booting entry is visible to the
    # sidebar filter (which keys off workspace_id, not working_dir).
    # Without this, booting agents silently disappear from the
    # sidebar until their session comes up and overwrites the ETS row
    # with a fully-populated summary.
    workspace_id =
      Keyword.get(opts, :workspace_id) ||
        Loopyard.Workspace.workspace_id(working_dir)

    stub = %__MODULE__{
      id: id,
      name: name,
      working_dir: working_dir,
      workspace_id: workspace_id,
      workstation_identity: Keyword.get(opts, :workstation_identity) || Loopyard.Workstation.current(),
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
      case Registry.lookup(Loopyard.ChatAgentRegistry, summary.id) do
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
    Loopyard.Events.ChatAgent.subscribe()
  end

  def subscribe(agent_id) do
    Loopyard.Events.ChatAgentMessage.subscribe(agent_id)
  end

  def unsubscribe(agent_id) do
    Loopyard.Events.ChatAgentMessage.unsubscribe(agent_id)
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
      Loopyard.Harness.Questions.pending_for_agent?(state.id) ->
        user_msg = %{role: :user, content: text, timestamp: DateTime.utc_now()}
        {state, user_msg} = append_message(state, user_msg)
        Persistence.persist_message(state, user_msg)

        Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{
          agent_id: state.id,
          msg: user_msg
        })

        Loopyard.Harness.Questions.answer_with_text(state.id, text)
        {:noreply, state}

      # Agent-sanity #15. If a turn is already in flight (:thinking)
      # or pending restart (:backoff), starting a second stream Task
      # against the same Claude session risks interleaved events or
      # an error from the SDK's query_queue. Record the message so
      # the user sees it didn't vanish, then enqueue for
      # post-turn drain. The turn-completion handlers
      # (:stream_done / :stream_error / :stream_timeout) pop the
      # queue and resume sends in order.
      state.status in [:thinking, :backoff] ->
        # Turn-taking: the agent holds the turn, so park the message in the
        # pending queue instead of slapping it into the chat stream (which
        # interleaved user bubbles + "Queued" notes through the agent's
        # reasoning). It surfaces in the queue panel under the live activity,
        # and only enters the chat history when it's actually sent on drain.
        state = %{state | pending_sends: state.pending_sends ++ [text]}
        # Refresh the ETS summary so the live queue panel updates.
        :ets.insert(@ets_table, {state.id, summary(state)})
        Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: state.id, status: state.status})
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

        Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{
          agent_id: state.id,
          msg: user_msg
        })

        wait_s =
          case StreamHandler.compute_rate_limit_wait_ms(state.rate_limit_resets_at_ms) do
            n when is_integer(n) -> div(n, 1000)
            _ -> 60
          end

        hold_msg = %{
          role: :system,
          content: "Holding your message — rate-limited, retrying in ~#{wait_s}s.",
          timestamp: DateTime.utc_now()
        }

        {state, hold_msg} = append_message(state, hold_msg)

        Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{
          agent_id: state.id,
          msg: hold_msg
        })

        {:noreply, state}

      state.status == :auth_expired ->
        # No recovery path — the CLI can't reach the API. Record the
        # send attempt so the user sees their message, then surface
        # the same auth-expired error again so they know nothing is
        # going to happen until they re-authenticate.
        user_msg = %{role: :user, content: text, timestamp: DateTime.utc_now()}
        {state, user_msg} = append_message(state, user_msg)
        Persistence.persist_message(state, user_msg)

        Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{
          agent_id: state.id,
          msg: user_msg
        })

        auth_msg = %{
          role: :error,
          content:
            "Can't send — Claude CLI auth is expired (#{state.auth_error}). Re-auth and restart the agent.",
          timestamp: DateTime.utc_now()
        }

        {state, auth_msg} = append_message(state, auth_msg)

        Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{
          agent_id: state.id,
          msg: auth_msg
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
  def handle_cast(:restart_session, state) do
    # Stop the current session
    if state.session do
      # Wrap backend.stop in a Task + Task.yield with timeout so a
      # hung CLI stop doesn't block the GenServer indefinitely. Also
      # wrap in try/catch so a raise inside backend.stop (or a crashed
      # Task) doesn't take down the caller — Task.yield EXITS the
      # caller with the task's exit reason if the task crashes.
      SessionManager.stop_backend(state.session, state.backend)
    end

    # Start a fresh session with the same opts. When we have a Claude
    # session_id captured from prior turns, pass it as `resume:` so the
    # CLI picks up the same conversation.
    case state.backend.start_session(SessionManager.build_resume_opts(state)) do
      {:ok, new_session} ->
        # A reboot is a full reset-to-idle — clear EVERY piece of transient turn
        # state, or the agent looks idle while the stream machinery thinks a turn
        # is live (stale stream_ref), and the next send is silently swallowed.
        state =
          SessionManager.track_os_pid(%{
            state
            | session: new_session,
              status: :idle,
              stream_ref: nil,
              active_tool: nil,
              in_flight_partial: "",
              tool_calls_this_turn: 0,
              tool_runaway_warned: false,
              last_tool_call: nil,
              context_warning_sent: false
          })

        :ets.insert(@ets_table, {state.id, summary(state)})
        Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: state.id, status: :idle})

        restart_msg =
          if is_binary(state.claude_session_id) do
            %{
              role: :system,
              content:
                "CLI session restarted (resumed conversation #{String.slice(state.claude_session_id, 0..7)}…)",
              timestamp: DateTime.utc_now()
            }
          else
            %{role: :system, content: "CLI session restarted", timestamp: DateTime.utc_now()}
          end

        {state, restart_msg} = append_message(state, restart_msg)

        Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{
          agent_id: state.id,
          msg: restart_msg
        })

        # Fallback when we don't have a CLI session_id yet (e.g. the
        # agent was restarted before its first ResultMessage landed).
        # With a session_id, `resume:` already restored the full
        # conversation — no need to pollute it with a summary prompt.
        if is_nil(state.claude_session_id) do
          resume_msg = Loopyard.ChatAgent.ResumeMessage.build(state.messages)

          if resume_msg do
            GenServer.cast(self(), {:send_message, resume_msg})
          end
        end

        # Drain a message the user queued while the harness was wedged onto the
        # fresh CLI (one at a time — the rest pop on turn completion, which
        # batches). NOT batched here: if the backend is permanently dead, this
        # recovery path loops, and batching would nest the queue exponentially.
        state =
          case state.pending_sends do
            [next | rest] ->
              GenServer.cast(self(), {:send_message, next})
              %{state | pending_sends: rest}

            [] ->
              state
          end

        {:noreply, state}

      {:error, reason} ->
        error_msg = %{
          role: :error,
          content:
            "Failed to restart the agent session: #{inspect(reason)}. " <>
              "WHY: the agent harness failed to start — usually auth, " <>
              "the harness not being installed in the container, or a bad working directory. " <>
              "CONSEQUENCE: this agent can't accept new messages. " <>
              "ACTION: check the harness is installed in the container, " <>
              "then click Restart in the sidebar. If restart keeps failing, " <>
              "remove the agent and create a new one.",
          timestamp: DateTime.utc_now()
        }

        {state, error_msg} = append_message(state, error_msg)
        state = %{state | errors: state.errors + 1}

        Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{
          agent_id: state.id,
          msg: error_msg
        })

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

    # Stop old session
    if state.session do
      task = Task.async(fn -> state.backend.stop(state.session) end)
      Task.yield(task, 3_000) || Task.shutdown(task, :brutal_kill)
    end

    # Start fresh session
    case state.backend.start_session(SessionManager.build_resume_opts(state)) do
      {:ok, new_session} ->
        state = %{
          state
          | session: new_session,
            status: :idle,
            context_utilization: 0.0,
            context_warning_sent: false
        }

        # Send the resume summary
        resume = Loopyard.ChatAgent.ResumeMessage.build(state.messages)
        if resume, do: GenServer.cast(self(), {:send_message, resume})

        # Re-send the user's last message so the agent acts on it
        if last_user_text && last_user_text != "" do
          GenServer.cast(self(), {:send_message, last_user_text})
        end

        :ets.insert(@ets_table, {id, summary(state)})
        Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: id, status: :idle})
        {:noreply, state}

      {:error, _} ->
        err = %{
          role: :error,
          content: "Failed to restart session. Start a new agent to continue.",
          timestamp: DateTime.utc_now()
        }

        {state, err} = append_message(state, err)
        Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{agent_id: id, msg: err})
        {:noreply, state}
    end
  end

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
    {:noreply, StreamHandler.process_event(event, state)}
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

      {:drain, list, state} ->
        send_batch(state, list)

      {:noreply, state} ->
        {:noreply, state}
    end
  end

  # Stale stream_done — belongs to a replaced stream, ignore.
  def handle_info({:stream_done, _id, _ref}, state), do: {:noreply, state}

  @impl true
  def handle_info(
        {:stream_timeout, id, ref},
        %{id: id, status: :thinking, stream_ref: ref} = state
      ) do
    case StreamHandler.on_stream_timeout(state) do
      {:reboot, state} ->
        # Reboot the CLI with resume — clears the wedge, keeps the full chat
        # history, continues the conversation. Queued messages drain onto the
        # fresh CLI inside the restart path.
        GenServer.cast(self(), :restart_session)
        {:noreply, state}
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
          GenServer.cast(self(), {:send_message, resume_msg})
        end

        {:noreply, state}

      {:drain, list, state} ->
        send_batch(state, list)

      {:noreply, state} ->
        {:noreply, state}
    end
  end

  # Linked streaming task died — auto-restart session with backoff.
  # Without backoff, a deterministic crash (e.g. tools/list serialization
  # bug) creates a hot restart loop that hammers the Claude API until
  # rate-limited.
  @max_consecutive_crashes 5
  # Configurable via Application env for tests:
  #   Application.put_env(:loopyard, :crash_backoff_base_ms, 0)
  @default_crash_backoff_base_ms 2_000

  @impl true
  def handle_info({:EXIT, _pid, reason}, %{status: :thinking} = state) when reason != :normal do
    Loopyard.EventLog.warning("agent:#{state.name}", "Streaming task died: #{inspect(reason)}")
    id = state.id
    consecutive = Map.get(state, :consecutive_crashes, 0) + 1

    if consecutive > @max_consecutive_crashes do
      error_msg = %{
        role: :error,
        content:
          "Agent crashed #{consecutive} times in a row — giving up to protect the harness API from hot-loop retries. " <>
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

      Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{
        agent_id: id,
        msg: error_msg
      })

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
      base =
        Application.get_env(:loopyard, :crash_backoff_base_ms, @default_crash_backoff_base_ms)

      backoff_ms = Loopyard.Retry.backoff_ms(consecutive, {:exponential, base})

      Loopyard.EventLog.info(
        "agent:#{state.name}",
        "Backing off #{backoff_ms}ms before restart (crash ##{consecutive})"
      )

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

  # Fired by handle_rate_limit_event when a :rejected status was seen.
  # We scheduled this for ~`resets_at_ms`. On fire, only flip back to
  # idle if the agent is still in :rate_limited (another path may have
  # moved it; don't stomp). Let the user's next send_message actually
  # try the CLI again — if we're still rate-limited, the CLI will
  # emit another :rejected and we'll re-schedule.
  def handle_info({:rate_limit_retry, id}, %{id: id, status: :rate_limited} = state) do
    state = %{state | status: :idle, rate_limit_status: :ok, rate_limit_resets_at_ms: nil}
    :ets.insert(@ets_table, {id, summary(state)})
    Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: id, status: :idle})

    resumed_msg = %{
      role: :system,
      content: "Rate-limit window cleared. Send a message to continue.",
      timestamp: DateTime.utc_now()
    }

    {state, resumed_msg} = append_message(state, resumed_msg)

    Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{
      agent_id: id,
      msg: resumed_msg
    })

    case state.pending_sends do
      [] -> {:noreply, state}
      [head | rest] -> send_message_normal(%{state | pending_sends: rest}, head)
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
  # The normal (non-rate-limited, non-auth-expired) path of
  # handle_cast({:send_message, text}). Kept as a defp so the cast
  # clauses stay contiguous (Elixir warns on non-grouped clauses) and
  # the cond in send_message stays readable.
  defp send_message_normal(state, text) do
    state = SessionManager.ensure_alive(state)

    if not state.backend.session_alive?(state.session) do
      # ensure_alive/1 just tried to (re)spawn the CLI and it's STILL
      # dead. Do NOT silently drop the message back to :idle — that's
      # the "swallow" bug: the user's text vanishes and the UI looks
      # idle as if nothing was sent. Instead: record a WHY/CONSEQUENCE/
      # ACTION error, queue the RAW text (drain_pending_sends re-runs
      # this fn, which appends the user message exactly once when a live
      # session finally takes it), and kick a restart.
      err = %{
        role: :error,
        timestamp: DateTime.utc_now(),
        content:
          "The Claude CLI session could not be started, so your message hasn't been sent yet.\n\n" <>
            "Your message is saved and queued — nothing was lost. It will be delivered " <>
            "automatically once the session reconnects.\n\n" <>
            "If this persists, restart the agent's session from the agent menu " <>
            "(Stop, then send again), or check /system/quarantine for a crash-looping agent."
      }

      {state, err_msg} = append_message(state, err)
      Persistence.persist_message(state, err_msg)

      Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{
        agent_id: state.id,
        msg: err_msg
      })

      state = %{state | pending_sends: state.pending_sends ++ [text]}
      Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: state.id, status: :idle})
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

      start_turn(state, text)
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
      state = %{state | pending_sends: list}
      Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: state.id, status: :idle})
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

      start_turn(state, Loopyard.Turn.batch_prompt(list))
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
          send(me, {:stream_error, agent_id, stream_ref, "CLI session exited: #{inspect(reason)}"})
      end
    end)

    Process.send_after(self(), {:stream_timeout, agent_id, stream_ref}, 600_000)
    {:noreply, %{state | stream_ref: stream_ref, in_flight_partial: ""}}
  end

  @max_messages 1000

  defp append_message(state, msg) do
    msg = Map.put_new_lazy(msg, :id, fn -> generate_msg_id() end)
    # Store as reverse list for O(1) prepend. Trim to cap.
    reversed = [msg | state.messages]

    reversed =
      if length(reversed) > @max_messages, do: Enum.take(reversed, @max_messages), else: reversed

    {%{state | messages: reversed}, msg}
  end

  defp generate_msg_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end

  defp via(id), do: {:via, Registry, {Loopyard.ChatAgentRegistry, id}}

  defp stuck_booting?(%{status: :booting, started_at: %DateTime{} = t}) do
    DateTime.diff(DateTime.utc_now(), t, :second) > @stuck_booting_seconds
  end

  defp stuck_booting?(_), do: false

  @doc false
  def summary(state) do
    %{
      id: state.id,
      name: state.name,
      working_dir: state.working_dir,
      bind_mount: state.bind_mount,
      workspace_id: state.workspace_id,
      workstation_identity: state.workstation_identity,
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
      context_utilization: state.context_utilization,
      pending_count: length(state.pending_sends),
      pending_messages: state.pending_sends
    }
  end

  @doc "Drop all queued (pending) messages without stopping the current turn."
  def clear_pending(id), do: GenServer.cast(via(id), :clear_pending)

  @doc "Remove a single queued message by its index in the pending queue."
  def remove_pending(id, index) when is_integer(index),
    do: GenServer.cast(via(id), {:remove_pending, index})

  # All broadcast from ChatAgent is done through the typed publisher
  # modules `Loopyard.Events.ChatAgent` (topic `"chat_agents"`) and
  # `Loopyard.Events.ChatAgentMessage` (topic `"chat_agent:{id}"`).
  # The CI boundary test enforces that no other code path calls
  # Phoenix.PubSub.broadcast directly.

  # --- Delegated public API ---

  @doc false
  defdelegate build_system_prompt(agent_id, opts), to: Prompt
end
