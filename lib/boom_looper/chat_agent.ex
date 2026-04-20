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
    turns: 0
  ]

  @ets_table :chat_agents

  # --- Public API ---

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: via(id))
  end

  def send_message(id, text) do
    GenServer.cast(via(id), {:send_message, text})
  end


  def get_state(id) do
    # Try live GenServer first, fall back to ETS
    try do
      GenServer.call(via(id), :get_state)
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
            GenServer.call(pid, :get_state, 2000)
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
        agent_type = saved[:agent_type] || BoomLooper.Agents.Registry.default_agent_name()

        {session, session_opts, backend} = start_session(id, opts,
          working_dir: saved.working_dir,
          bind_mount: saved.bind_mount,
          workspace_id: saved.workspace_id,
          service_name: saved[:service_name],
          agent_type: agent_type
        )

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
            messages: internal_messages
          )

        :ets.insert(@ets_table, {id, summary(state)})
        Events.ChatAgent.publish(%Events.ChatAgent.Resumed{summary: summary(state)})
        BoomLooper.EventLog.info("agent:#{state.name}", "Resumed (#{id}) with #{length(state.messages)} messages")

        {:ok, state}

      [] ->
        {:stop, :no_saved_state}
    end
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

    {session, session_opts, backend} = start_session(id, opts,
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
      agent_type: agent_type
    }

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

    {:ok, session} = backend.start_session(session_opts)
    {session, session_opts, backend}
  end

  @impl true
  # --- Message flow ---
  #
  # send_message/stop/restart_session/rename are the hot path for user
  # (and agent→agent, now gated) interaction. Appending messages,
  # broadcasting to subscribers, and journaling to the ETF log all
  # happen here.

  def handle_cast({:send_message, text}, state) do
    :telemetry.execute([:boom_looper, :agent, :message], %{}, %{agent_id: state.id, role: :user})

    # Auto-restart session if dead
    state = ensure_session_alive(state)

    # Add user message
    user_msg = %{role: :user, content: text, timestamp: DateTime.utc_now()}
    {state, user_msg} = append_message(state, user_msg)
    Persistence.persist_message(state,user_msg)

    # Broadcast with ID (last message has the ID assigned by append_message)
    Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{agent_id: state.id, msg: user_msg})

    # Don't try to stream if session is still dead
    if not state.backend.session_alive?(state.session) do
      Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: state.id, status: :idle})
      {:noreply, state}
    else
      state = %{state | status: :thinking}
      Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: state.id, status: :thinking})

      # Stream the response in a linked Task so we detect crashes
      me = self()
      agent_id = state.id
      session = state.session
      backend = state.backend

      Task.start_link(fn ->
        try do
          backend.stream(session, text)
          |> Enum.each(fn event ->
            send(me, {:stream_event, agent_id, event})
          end)

          send(me, {:stream_done, agent_id})
        rescue
          e ->
            send(me, {:stream_error, agent_id, Exception.message(e)})
        catch
          :exit, reason ->
            send(me, {:stream_error, agent_id, "CLI session exited: #{inspect(reason)}"})
        end
      end)

      # Safety timeout — if no stream events arrive within 10 minutes, reset to idle.
      # Long timeout needed because MCP tool calls (exec, rebuild) can block for minutes
      # while installing deps, running migrations, or building Docker images.
      # Use a unique ref so stale timeouts from previous streams are ignored.
      stream_ref = make_ref()
      Process.send_after(self(), {:stream_timeout, agent_id, stream_ref}, 600_000)

      {:noreply, %{state | stream_ref: stream_ref}}
    end
  end

  @impl true
  def handle_cast(:stop, state) do
    if state.session do
      # Stop in a task with timeout — backend.stop can hang if mid-stream
      task = Task.async(fn -> state.backend.stop(state.session) end)
      Task.yield(task, 3_000) || Task.shutdown(task, :brutal_kill)
    end

    stopped = %{state | status: :stopped}
    :ets.insert(@ets_table, {state.id, summary(stopped)})
    Events.ChatAgent.publish(%Events.ChatAgent.Stopped{summary: summary(stopped)})
    {:stop, :normal, stopped}
  end

  @impl true
  def handle_cast(:restart_session, state) do
    # Stop the current session
    if state.session do
      task = Task.async(fn -> state.backend.stop(state.session) end)
      Task.yield(task, 3_000) || Task.shutdown(task, :brutal_kill)
    end

    # Start a fresh session with the same opts
    case state.backend.start_session(state.session_opts) do
      {:ok, new_session} ->
        state = %{state | session: new_session, status: :idle}
        :ets.insert(@ets_table, {state.id, summary(state)})
        Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: state.id, status: :idle})

        restart_msg = %{role: :system, content: "CLI session restarted", timestamp: DateTime.utc_now()}
        {state, restart_msg} = append_message(state, restart_msg)
        Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{agent_id: state.id, msg: restart_msg})

        # Send context summary so the agent knows what it was working on.
        # Without this, a restart wipes all context — the agent wakes up
        # with amnesia and the user has to re-explain everything.
        resume_msg = build_resume_message(state)
        if resume_msg do
          GenServer.cast(self(), {:send_message, resume_msg})
        end

        {:noreply, state}

      {:error, reason} ->
        error_msg = %{role: :error, content: "Failed to restart session: #{inspect(reason)}", timestamp: DateTime.utc_now()}
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
    old_msg = Enum.find(state.messages, &(&1[:id] == msg_id))
    messages = Enum.map(state.messages, fn msg ->
      if msg[:id] == msg_id, do: update_fn.(msg), else: msg
    end)
    state = %{state | messages: messages}
    :ets.insert(@ets_table, {state.id, summary(state)})

    # Persist the changes (diff between old and new)
    new_msg = Enum.find(state.messages, &(&1[:id] == msg_id))
    if old_msg && new_msg do
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

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, summary(state), state}
  end

  @impl true
  # --- Stream event handling ---
  #
  # The Claude SDK streams events (:stream_event, :stream_done,
  # :stream_timeout, :stream_error) as the CLI produces output. These
  # clauses maintain the agent's in-flight message, broadcast chunks
  # to viewers via PubSub, and transition the agent's status when a
  # turn completes or fails.

  def handle_info({:stream_event, id, event}, %{id: id} = state) do
    now = DateTime.utc_now()

    state =
      case event do
        %Event.Text{text: content} ->
          assistant_msg = %{role: :assistant, content: content, timestamp: now}
          {state, assistant_msg} = append_message(state, assistant_msg)
        state = %{state | last_activity_at: now}
          Persistence.persist_message(state,assistant_msg)
          Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{agent_id: id, msg: assistant_msg})
          state

        %Event.ToolCall{name: tool_name, input: tool_input} ->
          tool_msg = %{role: :tool, tool: tool_name, input: tool_input, timestamp: now}
          {state, tool_msg} = append_message(state, tool_msg)
          state = %{state | last_activity_at: now, tool_calls: state.tool_calls + 1, active_tool: tool_name}
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
          # Don't persist deltas - they're just streaming UI updates
          Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.TextDelta{agent_id: id, text: text})
          state

        %Event.SessionResult{} = result ->
          # Accumulate token usage across turns. Persist after ETS
          # insert — without this, tokens live only in RAM, and a
          # server restart replays the original :agent record (frozen
          # at init_fresh) so the Claude panel zeroes out.
          state = %{state |
            model: result.model || state.model,
            total_input_tokens: state.total_input_tokens + result.input_tokens,
            total_output_tokens: state.total_output_tokens + result.output_tokens,
            total_cache_read_tokens: state.total_cache_read_tokens + result.cache_read_tokens,
            total_cost_usd: state.total_cost_usd + result.cost_usd
          }
          :ets.insert(@ets_table, {id, summary(state)})
          Persistence.persist_agent(state, &summary/1)
          Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: id, status: state.status})
          state

        _ ->
          state
      end

    {:noreply, state}
  end

  @impl true
  def handle_info({:stream_done, id}, %{id: id} = state) do
    # Turn counter and transient tool/ref are part of summary — without
    # ETS sync + persist here, UI reads stale data and restart replay
    # loses the increment.
    state = %{state | status: :idle, active_tool: nil, turns: state.turns + 1}
    state = Map.put(state, :consecutive_crashes, 0)
    :ets.insert(@ets_table, {id, summary(state)})
    Persistence.persist_agent(state, &summary/1)
    Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: id, status: :idle})
    {:noreply, state}
  end

  @impl true
  def handle_info({:stream_timeout, id, ref}, %{id: id, status: :thinking, stream_ref: ref} = state) do
    # Still thinking after timeout AND ref matches current stream — the streaming task is gone
    BoomLooper.EventLog.warning("agent:#{state.name}", "Stream timed out, resetting to idle")
    error_msg = %{role: :error, content: "Agent stopped responding. Send a message to retry.", timestamp: DateTime.utc_now()}
    {state, error_msg} = append_message(state, error_msg)
        state = %{state | status: :idle, errors: state.errors + 1}
    Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{agent_id: id, msg: error_msg})
    Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: id, status: :idle})
    {:noreply, state}
  end

  # Ignore timeout if ref doesn't match (stale timer from previous stream) or not thinking
  @impl true
  def handle_info({:stream_timeout, _id, _ref}, state), do: {:noreply, state}

  # Legacy timeout format (no ref) — ignore
  @impl true
  def handle_info({:stream_timeout, _id}, state), do: {:noreply, state}

  @impl true
  def handle_info({:stream_error, id, reason}, %{id: id} = state) do
    BoomLooper.EventLog.error("agent:#{state.name}", "Stream error: #{reason}")
    now = DateTime.utc_now()

    # Count recent crashes (within last 60 seconds)
    recent_crashes = state.messages
      |> Enum.filter(fn m -> m.role == :system && m.content == "Agent crashed — restarting..." &&
         DateTime.diff(now, m.timestamp, :second) < 60 end)
      |> length()

    if is_binary(reason) && String.contains?(reason, "CLI session exited") && recent_crashes < 2 do
      # CLI died — restart session but don't replay (let user decide what to do)
      state = %{state | last_activity_at: now, errors: state.errors + 1}

      case state.backend.start_session(state.session_opts) do
        {:ok, new_session} ->
          recovered_msg = %{role: :system, content: "Agent session restarted automatically.", timestamp: DateTime.utc_now()}
          {state, recovered_msg} = append_message(%{state | session: new_session, status: :idle}, recovered_msg)
          Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{agent_id: id, msg: recovered_msg})
          Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: id, status: :idle})

          # Auto-continue: send the agent a summary of what it was doing so it can resume
          resume_msg = build_resume_message(state)
          if resume_msg do
            GenServer.cast(self(), {:send_message, resume_msg})
          end

          {:noreply, state}

        {:error, _} ->
          fail_msg = %{role: :error, content: "Agent session crashed and failed to restart", timestamp: DateTime.utc_now()}
          {state, fail_msg} = append_message(state, fail_msg)
        state = %{state | status: :idle}
          Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{agent_id: id, msg: fail_msg})
          Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: id, status: :idle})
          {:noreply, state}
      end
    else
      error_msg = %{role: :error, content: reason, timestamp: now}
      {state, error_msg} = append_message(state, error_msg)
        state = %{state | status: :idle, last_activity_at: now, errors: state.errors + 1}
      Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{agent_id: id, msg: error_msg})
      Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: id, status: :idle})
      {:noreply, state}
    end
  end

  # Linked streaming task died — auto-restart session with backoff.
  # Without backoff, a deterministic crash (e.g. tools/list serialization
  # bug) creates a hot restart loop that hammers the Claude API until
  # rate-limited.
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
      error_msg = %{role: :error, content: "Agent crashed #{consecutive} times in a row — giving up. Fix the underlying issue and restart manually.", timestamp: DateTime.utc_now()}
      {state, error_msg} = append_message(state, error_msg)
      state = %{state | status: :crashed, errors: state.errors + 1}
      state = Map.put(state, :consecutive_crashes, consecutive)
      Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{agent_id: id, msg: error_msg})
      Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: id, status: :crashed})
      {:noreply, state}
    else
      # Exponential backoff scheduled via `Process.send_after` — NOT
      # synchronous sleep. A previous version slept inside this
      # handler for up to 32s, blocking the mailbox: send_message
      # casts, :stop, Claude stream events, and PubSub traffic all
      # queued until the sleep returned. Move #7d's `backoff_ms/2`
      # exists precisely so ChatAgent crash recovery can be an
      # async sequence of `handle_info` events rather than a
      # blocking loop. Schedule + return :noreply; the retry happens
      # in `handle_info({:retry_session, consecutive})` below.
      base = Application.get_env(:boom_looper, :crash_backoff_base_ms, @default_crash_backoff_base_ms)
      backoff_ms = BoomLooper.Retry.backoff_ms(consecutive, {:exponential, base})
      BoomLooper.EventLog.info("agent:#{state.name}", "Backing off #{backoff_ms}ms before restart (crash ##{consecutive})")
      Process.send_after(self(), {:retry_session, consecutive}, backoff_ms)
      state = Map.put(state, :consecutive_crashes, consecutive)
      {:noreply, state}
    end
  end

  # Scheduled by the :EXIT handler above after the backoff window.
  # Actually performs the session restart + appends the outcome
  # message. Kept out of the :EXIT handler so the mailbox stays
  # responsive during the backoff.
  @impl true
  def handle_info({:retry_session, consecutive}, state) do
    id = state.id

    case state.backend.start_session(state.session_opts) do
      {:ok, new_session} ->
        recovered_msg = %{
          role: :system,
          content: "Session crashed — restarted automatically (attempt #{consecutive}).",
          timestamp: DateTime.utc_now()
        }

        {state, recovered_msg} =
          append_message(
            %{state | session: new_session, status: :idle, errors: state.errors + 1},
            recovered_msg
          )

        state = Map.put(state, :consecutive_crashes, consecutive)
        Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{agent_id: id, msg: recovered_msg})
        Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: id, status: :idle})
        {:noreply, state}

      {:error, _} ->
        error_msg = %{
          role: :error,
          content: "Agent session crashed. Send a message to retry.",
          timestamp: DateTime.utc_now()
        }

        {state, error_msg} = append_message(state, error_msg)
        state = %{state | status: :idle, errors: state.errors + 1}
        state = Map.put(state, :consecutive_crashes, consecutive)
        Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{agent_id: id, msg: error_msg})
        Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: id, status: :idle})
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(msg, state) do
    # Log + telemetry for unknown messages (framework-fighting fix
    # from plans/post-migration-audit.md). Unknown mailbox traffic
    # previously landed in a silent `{:noreply, state}` catch-all,
    # which is exactly how "why isn't my handler firing?" debug
    # sessions started.
    Logger.warning("[ChatAgent] #{state.id} unhandled message: #{inspect(msg, limit: 200)}")

    :telemetry.execute(
      [:boom_looper, :actor, :unknown_message],
      %{count: 1},
      %{actor: __MODULE__, agent_id: state.id, msg: inspect(msg, limit: 200)}
    )

    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Always stop the Claude CLI session to prevent process leaks.
    # Port.close alone doesn't kill the OS process — we must find and kill it.
    if state.session && state.backend do
      # Grab the OS PID before stopping (the port will be gone after stop)
      os_pid = BoomLooper.ChatAgent.OSProcess.pid_of(state.session)

      try do
        task = Task.async(fn -> state.backend.stop(state.session) end)
        Task.yield(task, 3_000) || Task.shutdown(task, :brutal_kill)
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end

      # Force-kill the OS process if it's still around
      if os_pid, do: BoomLooper.ChatAgent.OSProcess.kill(os_pid)
    end

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

      case state.backend.start_session(state.session_opts) do
        {:ok, new_session} ->
          BoomLooper.EventLog.info("agent:#{state.name}", "CLI session restarted")
          ok_msg = %{role: :system, content: "Reconnected.", timestamp: DateTime.utc_now()}
          {state, ok_msg} = append_message(%{state | session: new_session}, ok_msg)
          Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{agent_id: state.id, msg: ok_msg})
          state

        {:error, reason} ->
          BoomLooper.EventLog.error("agent:#{state.name}", "Failed to restart CLI: #{inspect(reason)}")
          fail_msg = %{role: :error, content: "Failed to reconnect: #{inspect(reason)}", timestamp: DateTime.utc_now()}
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
      turns: state.turns
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
