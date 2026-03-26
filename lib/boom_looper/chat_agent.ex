defmodule BoomLooper.ChatAgent do
  @moduledoc """
  GenServer wrapping a Claude Code SDK session.
  Streams structured messages to viewers via PubSub.
  Unlike the PTY-based Agent, this uses the JSON protocol
  for a proper multiplayer chat experience.
  """
  use GenServer, restart: :transient
  require Logger

  alias BoomLooper.Agent.Event
  alias BoomLooper.AgentLog


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
    :checklist_path,
    :service_name,
    status: :idle,
    messages: [],
    tool_calls: 0,
    errors: 0
  ]

  @topic "chat_agents"
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
        ensure_ets_table()

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
        ensure_ets_table()

        case :ets.lookup(@ets_table, id) do
          [{^id, summary}] ->
            stopped = %{summary | status: :stopped}
            :ets.insert(@ets_table, {id, stopped})
            broadcast(@topic, {:chat_agent_stopped, stopped})

          [] ->
            :ok
        end

        # Force-stop the GenServer (kills linked streaming task too)
        GenServer.stop(pid, :normal, 5_000)

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
        # Give the GenServer a moment to process
        Process.sleep(10)
        msg

      [] ->
        # No GenServer running — direct ETS write
        ensure_ets_table()
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
        ensure_ets_table()
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

  @doc "Remove a stopped/crashed agent — transitions to :destroying, cleans up Docker, then removes from sidebar"
  def remove_agent(id) do
    ensure_ets_table()

    # Transition to :destroying so all viewers see the state
    case :ets.lookup(@ets_table, id) do
      [{^id, summary}] ->
        destroying = %{summary | status: :destroying}
        :ets.insert(@ets_table, {id, destroying})
        broadcast(@topic, {:chat_agent_status_changed, id, :destroying})

      [] ->
        :ok
    end

    # Remove from sidebar — no per-agent Docker cleanup needed
    # (workspace container is shared and managed by ServiceManager)
    Task.start(fn ->
      :ets.delete(@ets_table, id)
      broadcast(@topic, {:chat_agent_removed, id})
    end)
  end

  @doc "Register an agent as booting in ETS so all viewers can see it"
  def register_booting(id, name, working_dir, opts \\ []) do
    ensure_ets_table()

    summary = %{
      id: id,
      name: name,
      working_dir: working_dir,
      service_name: Keyword.get(opts, :service_name),
      started_at: DateTime.utc_now(),
      started_by: "browser",
      last_activity_at: DateTime.utc_now(),
      status: :booting,
      messages: [],
      tool_calls: 0,
      errors: 0,
      boot_status: "Initializing..."
    }

    :ets.insert(@ets_table, {id, summary})
    broadcast(@topic, {:chat_agent_booting, summary})
    summary
  end

  @doc "Update boot status in ETS and broadcast to all viewers"
  def update_boot_status(id, status_text) do
    ensure_ets_table()

    case :ets.lookup(@ets_table, id) do
      [{^id, summary}] ->
        updated = %{summary | boot_status: status_text, last_activity_at: DateTime.utc_now()}
        :ets.insert(@ets_table, {id, updated})
        broadcast(@topic, {:chat_agent_boot_status, id, status_text})

      [] ->
        :ok
    end
  end

  @doc "Mark a booting agent as failed and remove it"
  def boot_failed(id, reason) do
    ensure_ets_table()
    :ets.delete(@ets_table, id)
    broadcast(@topic, {:chat_agent_boot_failed, id, reason})
  end

  def list_agents do
    ensure_ets_table()

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
        [] -> summary
      end
    end)
    |> Enum.sort_by(& &1[:started_at], {:desc, DateTime})
  end

  def ensure_ets_table do
    if :ets.whereis(@ets_table) == :undefined do
      :ets.new(@ets_table, [:named_table, :public, :set])
    end

    :ok
  end

  def subscribe do
    Phoenix.PubSub.subscribe(BoomLooper.PubSub, @topic)
  end

  def subscribe(agent_id) do
    Phoenix.PubSub.subscribe(BoomLooper.PubSub, "chat_agent:#{agent_id}")
  end

  def unsubscribe(agent_id) do
    Phoenix.PubSub.unsubscribe(BoomLooper.PubSub, "chat_agent:#{agent_id}")
  end

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

  # Resume an agent from persisted state (after server restart)
  defp init_resume(id, opts) do
    ensure_ets_table()

    case :ets.lookup(@ets_table, id) do
      [{^id, saved}] ->
        # Restore from saved state
        bind_mount = saved.bind_mount
        workspace = if bind_mount, do: load_workspace_config(bind_mount), else: nil
        workspace_id = saved.workspace_id

        tools = Keyword.get(opts, :tools, default_tools())
        backend = Keyword.get(opts, :backend, BoomLooper.Agent.Backend.ClaudeCode)

        system_prompt = build_system_prompt(id, bind_mount, workspace_id, workspace, saved[:checklist_path], saved[:service_name])

        session_opts = [
          cwd: saved.working_dir,
          permission_mode: :accept_edits,
          dangerously_skip_permissions: true,
          mcp_servers: build_mcp_servers(tools),
          allowed_tools: build_allowed_tools(tools),
          system_prompt: system_prompt
        ]

        {:ok, session} = backend.start_session(session_opts)

        state = %__MODULE__{
          id: id,
          name: saved.name,
          session: session,
          session_opts: session_opts,
          backend: backend,
          working_dir: saved.working_dir,
          bind_mount: bind_mount,
          workspace_id: workspace_id,
          started_at: saved.started_at,
          started_by: saved.started_by,
          last_activity_at: DateTime.utc_now(),
          status: :idle,
          messages: saved.messages,
          tool_calls: saved[:tool_calls] || 0,
          errors: saved[:errors] || 0,
          checklist_path: saved[:checklist_path],
          service_name: saved[:service_name]
        }

        # Update ETS with live status
        :ets.insert(@ets_table, {id, summary(state)})
        broadcast(@topic, {:chat_agent_resumed, summary(state)})
        BoomLooper.EventLog.info("agent:#{state.name}", "Resumed (#{id}) with #{length(state.messages)} messages")

        {:ok, state}

      [] ->
        # No saved state - can't resume
        {:stop, :no_saved_state}
    end
  end

  # Start a fresh agent (normal path)
  defp init_fresh(id, opts) do
    name = Keyword.get(opts, :name, "Chat #{id |> String.slice(0..7)}")
    working_dir = Keyword.get(opts, :working_dir, File.cwd!())
    started_by = Keyword.get(opts, :started_by, "anonymous")

    # Tool modules the agent has access to
    tools = Keyword.get(opts, :tools, default_tools())
    bind_mount = Keyword.get(opts, :bind_mount)

    # Load workspace config if a bind mount exists
    workspace = if bind_mount, do: load_workspace_config(bind_mount), else: nil
    workspace_id = if bind_mount, do: BoomLooper.Workspace.workspace_id(bind_mount), else: nil
    checklist_path = Keyword.get(opts, :checklist_path)
    service_name = Keyword.get(opts, :service_name)

    system_prompt = build_system_prompt(id, bind_mount, workspace_id, workspace, checklist_path, service_name)

    backend = Keyword.get(opts, :backend, BoomLooper.Agent.Backend.ClaudeCode)

    session_opts =
      [
        cwd: working_dir,
        permission_mode: :accept_edits,
        dangerously_skip_permissions: true,
        mcp_servers: build_mcp_servers(tools),
        allowed_tools: build_allowed_tools(tools)
      ]

    session_opts = Keyword.put(session_opts, :system_prompt, system_prompt)

    {:ok, session} = backend.start_session(session_opts)

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
      checklist_path: checklist_path,
      service_name: service_name
    }

    summary = summary(state)
    :ets.insert(@ets_table, {id, summary})
    persist_agent(state)
    broadcast(@topic, {:chat_agent_started, summary})
    BoomLooper.EventLog.info("agent:#{name}", "Started (#{id})")

    {:ok, state}
  end

  @impl true
  def handle_cast({:send_message, text}, state) do
    # Auto-restart session if dead
    state = ensure_session_alive(state)

    # Add user message
    user_msg = %{role: :user, content: text, timestamp: DateTime.utc_now()}
    state = append_message(state, user_msg)
    persist_message(state, List.last(state.messages))

    # Broadcast with ID (last message has the ID assigned by append_message)
    broadcast("chat_agent:#{state.id}", {:chat_message, state.id, List.last(state.messages)})

    # Don't try to stream if session is still dead
    unless state.backend.session_alive?(state.session) do
      broadcast(@topic, {:chat_agent_status_changed, state.id, :idle})
      {:noreply, state}
    else

    state = %{state | status: :thinking}
    broadcast(@topic, {:chat_agent_status_changed, state.id, :thinking})

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

    # Safety timeout — if no stream events arrive within 2 minutes, reset to idle
    Process.send_after(self(), {:stream_timeout, agent_id}, 120_000)

    {:noreply, state}
    end # unless session dead
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
    broadcast(@topic, {:chat_agent_stopped, summary(stopped)})
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
        broadcast(@topic, {:chat_agent_status_changed, state.id, :idle})

        restart_msg = %{role: :system, content: "CLI session restarted", timestamp: DateTime.utc_now()}
        state = append_message(state, restart_msg)
        broadcast("chat_agent:#{state.id}", {:chat_message, state.id, List.last(state.messages)})
        {:noreply, state}

      {:error, reason} ->
        error_msg = %{role: :error, content: "Failed to restart session: #{inspect(reason)}", timestamp: DateTime.utc_now()}
        state = %{append_message(state, error_msg) | errors: state.errors + 1}
        broadcast("chat_agent:#{state.id}", {:chat_message, state.id, List.last(state.messages)})
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:append_external_message, msg}, state) do
    state = append_message(state, msg)
    :ets.insert(@ets_table, {state.id, summary(state)})
    persist_message(state, List.last(state.messages))
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
      persist_message_update(state, msg_id, changes)
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:rename, new_name}, state) do
    state = %{state | name: new_name}
    broadcast(@topic, {:chat_agent_renamed, state.id, new_name})
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, summary(state), state}
  end

  @impl true
  def handle_info({:stream_event, id, event}, %{id: id} = state) do
    now = DateTime.utc_now()

    state =
      case event do
        %Event.Text{text: content} ->
          assistant_msg = %{role: :assistant, content: content, timestamp: now}
          state = %{append_message(state, assistant_msg) | last_activity_at: now}
          persist_message(state, List.last(state.messages))
          broadcast("chat_agent:#{id}", {:chat_message, id, List.last(state.messages)})
          state

        %Event.ToolCall{name: tool_name, input: tool_input} ->
          tool_msg = %{role: :tool, tool: tool_name, input: tool_input, timestamp: now}
          state = %{append_message(state, tool_msg) | last_activity_at: now, tool_calls: state.tool_calls + 1}
          persist_message(state, List.last(state.messages))
          broadcast("chat_agent:#{id}", {:chat_message, id, List.last(state.messages)})
          state

        %Event.ToolResult{content: content, is_error: is_error} ->
          result_msg = %{role: :tool_result, content: content, is_error: is_error, timestamp: now}
          state = %{append_message(state, result_msg) | last_activity_at: now}
          persist_message(state, List.last(state.messages))
          broadcast("chat_agent:#{id}", {:chat_message, id, List.last(state.messages)})
          state

        %Event.TextDelta{text: text} ->
          # Don't persist deltas - they're just streaming UI updates
          broadcast("chat_agent:#{id}", {:chat_text_delta, id, text})
          state

        _ ->
          state
      end

    {:noreply, state}
  end

  def handle_info({:stream_done, id}, %{id: id} = state) do
    state = %{state | status: :idle}
    broadcast(@topic, {:chat_agent_status_changed, id, :idle})
    {:noreply, state}
  end

  def handle_info({:stream_timeout, id}, %{id: id, status: :thinking} = state) do
    # Still thinking after timeout — the streaming task is gone
    BoomLooper.EventLog.warning("agent:#{state.name}", "Stream timed out, resetting to idle")
    error_msg = %{role: :error, content: "Agent stopped responding. Send a message to retry.", timestamp: DateTime.utc_now()}
    state = %{append_message(state, error_msg) | status: :idle, errors: state.errors + 1}
    broadcast("chat_agent:#{id}", {:chat_message, id, List.last(state.messages)})
    broadcast(@topic, {:chat_agent_status_changed, id, :idle})
    {:noreply, state}
  end

  # Ignore timeout if we're no longer thinking (stream completed normally)
  def handle_info({:stream_timeout, _id}, state), do: {:noreply, state}

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
          recovered_msg = %{role: :system, content: "Agent session restarted. Send a message to continue.", timestamp: DateTime.utc_now()}
          state = append_message(%{state | session: new_session, status: :idle}, recovered_msg)
          broadcast("chat_agent:#{id}", {:chat_message, id, List.last(state.messages)})
          broadcast(@topic, {:chat_agent_status_changed, id, :idle})
          {:noreply, state}

        {:error, _} ->
          fail_msg = %{role: :error, content: "Agent session crashed and failed to restart", timestamp: DateTime.utc_now()}
          state = %{append_message(state, fail_msg) | status: :idle}
          broadcast("chat_agent:#{id}", {:chat_message, id, List.last(state.messages)})
          broadcast(@topic, {:chat_agent_status_changed, id, :idle})
          {:noreply, state}
      end
    else
      error_msg = %{role: :error, content: reason, timestamp: now}
      state = %{append_message(state, error_msg) | status: :idle, last_activity_at: now, errors: state.errors + 1}
      broadcast("chat_agent:#{id}", {:chat_message, id, List.last(state.messages)})
      broadcast(@topic, {:chat_agent_status_changed, id, :idle})
      {:noreply, state}
    end
  end

  # Linked streaming task died — reset from thinking if needed
  def handle_info({:EXIT, _pid, reason}, %{status: :thinking} = state) when reason != :normal do
    BoomLooper.EventLog.warning("agent:#{state.name}", "Streaming task died: #{inspect(reason)}")
    error_msg = %{role: :error, content: "Agent session crashed. Send a message to retry.", timestamp: DateTime.utc_now()}
    state = %{append_message(state, error_msg) | status: :idle, errors: state.errors + 1}
    broadcast("chat_agent:#{state.id}", {:chat_message, state.id, List.last(state.messages)})
    broadcast(@topic, {:chat_agent_status_changed, state.id, :idle})
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(:normal, _state), do: :ok

  def terminate(_reason, state) do
    crashed = %{state | status: :crashed}
    :ets.insert(@ets_table, {state.id, summary(crashed)})
    broadcast(@topic, {:chat_agent_stopped, summary(crashed)})
  end

  # --- Private ---

  defp load_workspace_config(project_dir) do
    case BoomLooper.Workspace.load(project_dir) do
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
      broadcast("chat_agent:#{state.id}", {:chat_message, state.id, List.last(state.messages)})
      state = append_message(state, restart_msg)

      case state.backend.start_session(state.session_opts) do
        {:ok, new_session} ->
          BoomLooper.EventLog.info("agent:#{state.name}", "CLI session restarted")
          ok_msg = %{role: :system, content: "Reconnected.", timestamp: DateTime.utc_now()}
          broadcast("chat_agent:#{state.id}", {:chat_message, state.id, List.last(state.messages)})
          append_message(%{state | session: new_session}, ok_msg)

        {:error, reason} ->
          BoomLooper.EventLog.error("agent:#{state.name}", "Failed to restart CLI: #{inspect(reason)}")
          fail_msg = %{role: :error, content: "Failed to reconnect: #{inspect(reason)}", timestamp: DateTime.utc_now()}
          broadcast("chat_agent:#{state.id}", {:chat_message, state.id, List.last(state.messages)})
          append_message(state, fail_msg)
      end
    end
  end

  defp append_message(state, msg) do
    msg = Map.put_new_lazy(msg, :id, fn -> generate_msg_id() end)
    %{state | messages: state.messages ++ [msg]}
  end

  defp generate_msg_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end

  defp via(id), do: {:via, Registry, {BoomLooper.ChatAgentRegistry, id}}

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
      messages: state.messages,
      tool_calls: state.tool_calls,
      errors: state.errors,
      checklist_path: state.checklist_path,
      service_name: state.service_name
    }
  end

  defp broadcast(topic, message) do
    Phoenix.PubSub.broadcast(BoomLooper.PubSub, topic, message)
  end

  # --- Persistence ---

  @log_version 1

  defp log_path(nil), do: nil
  defp log_path(bind_mount) do
    Path.join([bind_mount, ".boomlooper", "workspace", "agents.log"])
  end

  defp persist_agent(state) do
    case log_path(state.bind_mount) do
      nil -> :ok
      path ->
        # Log the full summary so replay produces complete ETS entries
        agent_data = summary(state) |> Map.delete(:messages)
        AgentLog.append({:agent, state.id, agent_data}, log_path: path, version: @log_version)
    end
  end

  defp persist_message(state, msg) do
    case log_path(state.bind_mount) do
      nil -> :ok
      path -> AgentLog.append({:msg, state.id, msg}, log_path: path, version: @log_version)
    end
  end

  defp persist_message_update(state, msg_id, changes) do
    case log_path(state.bind_mount) do
      nil -> :ok
      path -> AgentLog.append({:msg_update, state.id, msg_id, changes}, log_path: path, version: @log_version)
    end
  end

  # --- System Prompt ---

  defp build_system_prompt(agent_id, bind_mount, workspace_id, workspace, checklist_path, service_name) do
    {base, workspace_section} =
      if workspace do
        {container_base_prompt(agent_id, bind_mount, workspace_id),
         workspace_prompt(workspace, bind_mount)}
      else
        {setup_base_prompt(agent_id, bind_mount),
         setup_prompt(bind_mount)}
      end

    checklist_section =
      if checklist_path do
        checklist_prompt(checklist_path)
      else
        ""
      end

    service_section =
      if service_name && workspace_id && workspace do
        service_agent_prompt(service_name, workspace_id, workspace)
      else
        ""
      end

    base <> "\n" <> workspace_section <> checklist_section <> service_section
  end

  defp service_agent_prompt(service_name, workspace_id, workspace) do
    {container, detail} =
      cond do
        svc = Enum.find(workspace.services, &(&1.name == service_name)) ->
          {BoomLooper.Workspace.ServiceManager.service_container_name(workspace_id, service_name),
           "Stock service running #{svc.image}"}

        proc = Enum.find(workspace.processes, &(&1.name == service_name)) ->
          {BoomLooper.Workspace.ServiceManager.process_container_name(workspace_id, service_name),
           "Process running: #{proc.command}"}

        true ->
          {"unknown", "Unknown service"}
      end

    """

    ## Service Agent: #{service_name}

    You are scoped to the "#{service_name}" service (container: #{container}).
    #{detail}

    Your primary job is to monitor, debug, and fix this service. Use the `logs` tool to check its output.
    You still have full workspace access via the container tools — use it to read code, run tests, and make fixes.
    Focus your attention on issues related to this service.
    """
  end

  defp container_base_prompt(agent_id, bind_mount, workspace_id) do
    container =
      if workspace_id do
        BoomLooper.Workspace.ServiceManager.service_container_name(workspace_id, "workspace")
      else
        "bl-unknown-workspace-1"
      end

    workspace_note =
      if bind_mount do
        "/workspace is a bind mount of #{bind_mount} — edits appear on the host immediately"
      else
        "/workspace is a Docker volume that persists independently"
      end

    """
    You share a workspace container "#{container}" with other agents. Your workspace is at /workspace.

    YOUR AGENT ID: #{agent_id}

    IMPORTANT: Use the boom-looper-container MCP tools for ALL work. Pass your agent_id "#{agent_id}" to every container tool call.

    ## How to work

    - **Run commands**: Use `exec` for quick commands (< 2 min). Use `exec_stream` for long-running commands — output streams live into the chat so the user can watch.
    - **When to use exec_stream**: Any command that runs for more than a few seconds or produces continuous output — builds, tests, servers, ping, tail -f, watch, bundle install, npm install, migrations, etc.
    - **Edit files**: Use `exec` with shell commands (cat, sed, tee, etc.) to read/write files in /workspace
    - **Install dependencies**: Use `exec_stream` to run apt-get, mix deps.get, npm install, pip install, etc. inside the container (these take time and the user wants to see progress)
    - **Check status**: Use `logs` to see container output, `ports` to see listeners, `inspect_env` for full environment info
    - **Rebuild**: Use the `rebuild` workspace tool to rebuild the container image after changing the Dockerfile

    ## Container details

    - #{workspace_note}
    - /root/.cache persists (package caches)
    - The dev server runs in a SEPARATE container. To reach it from exec, use the compose service name (e.g. `curl http://dev:PORT/`)
    - Use `service_status` to see container names and ports
    - Use `logs` with `service: "dev"` to see the dev server output

    Do NOT use your local Bash/Read/Write tools for project work — everything goes through the container tools.
    """
  end

  defp workspace_prompt(workspace, _bind_mount) do
    stock_section =
      case workspace.services do
        [] -> ""
        services ->
          lines = Enum.map(services, fn s ->
            ports = s[:ports] || %{}
            "- #{s.name}: #{s.image}" <>
            if(is_map(ports) && map_size(ports) > 0, do: " (ports: #{inspect(ports)})", else: "")
          end)
          "\nStock services on the Docker network:\n#{Enum.join(lines, "\n")}\n"
      end

    process_section =
      case workspace.processes do
        [] -> ""
        processes ->
          lines = Enum.map(processes, fn p ->
            ports = p[:ports] || []
            "- #{p.name}: #{p.command}" <>
            if(is_list(ports) && length(ports) > 0, do: " (ports: #{inspect(ports)})", else: "")
          end)
          "\nWorkspace processes (run inside the workspace container):\n#{Enum.join(lines, "\n")}\n"
      end

    custom = if workspace.system_prompt, do: "\n#{workspace.system_prompt}\n", else: ""

    """
    ## Workspace: #{workspace.name || "Unnamed"}
    #{stock_section}#{process_section}#{custom}
    """
  end

  defp setup_base_prompt(agent_id, _bind_mount) do
    """
    You are a Setup agent configuring a development environment.

    YOUR AGENT ID: #{agent_id}

    You are NOT inside a container yet. Your job is to:
    1. Read project files (README, Dockerfile, docker-compose.yml, Gemfile, etc.) to understand the project
    2. Use workspace tools to configure: `set_dockerfile`, `set_dev_command`, `add_service`, `set_env_vars`
    3. Call `rebuild` — this generates docker-compose.yml and runs `docker compose up --build`
    4. THEN use `exec` to run setup commands inside the workspace container (install deps, migrate db, etc.)
    5. Verify services are healthy with `service_status`

    Pass your agent_id "#{agent_id}" to every tool call.

    IMPORTANT: Do NOT use `exec` until AFTER `rebuild`. There is no container until the image is built.
    IMPORTANT: NEVER install software via runtime scripts (docker exec apt-get). It doesn't persist. Everything through the Dockerfile or image selection.

    ## Platform & architecture

    The host machine is macOS (likely Apple Silicon / ARM64). The container runs Linux ARM64 (aarch64).
    - Always use official multi-arch Docker images — they have ARM64 variants.
    - Prefer `apt-get install <package>` over building from source. Most tools are already in Debian/Ubuntu repos for arm64.
    - Never download x86_64 binaries. If a tool doesn't have an arm64 binary, check the distro package manager first before trying to build from source.
    - Keep it simple. Don't install things you don't need.

    **Service images must have ARM64 support.** Before calling `add_service`, verify the image has an ARM64 build:
    - `docker manifest inspect <image>:<tag> 2>&1 | grep architecture` — look for `arm64` or `aarch64`
    - If the error "no matching manifest for linux/arm64" appears during rebuild, the image doesn't support ARM64
    - Find an alternative ARM64-compatible image (e.g., `ghcr.io/baosystems/postgis` instead of `postgis/postgis`)
    - If no ARM64 image exists, tell the user — don't retry with the same image

    ## File watchers and bind mounts

    inotify/fsevents do NOT work reliably across Docker bind mounts. File watching tools (watchman, webpack, tailwind, esbuild, vite, nodemon, guard, etc.) will often fail to detect changes or spin endlessly.
    - **Always use polling mode** for file watchers in the dev command. Examples:
      - Tailwind CSS: `tailwindcss --watch --poll`
      - Webpack: `webpack --watch --watch-poll`
      - Vite: set `server.watch.usePolling: true`
      - Nodemon: `nodemon --legacy-watch`
      - Guard: `:polling` option
      - Rails/Ruby: If the project has a `Procfile.dev` that uses `tailwindcss:watch`, check if there's a `Procfile.container` or add `--poll` to the CSS watcher
    - Check Procfiles and dev scripts for file watchers before setting the dev command. Adapt them for container use.

    ## Ports are always dynamic

    Host ports are allocated dynamically by Docker — NEVER specify fixed host:container port mappings.
    - When calling `set_dev_command` or `add_service`, only specify the container port: `["3000"]` not `["3001:3000"]`.
    - If the project has an existing docker-compose.yml with fixed port mappings, ignore the host port. Only pass the container port.
    - Common patterns to strip: `"3000:3000"` → `"3000"`, `"5433:5432"` → `"5432"`

    ## Rebuilds and waiting

    After calling `rebuild`, the image builds and containers restart. The `rebuild` tool returns immediately.
    - Use `service_status` to check if containers are running. Call it ONCE after rebuild.
    - **NEVER use `sleep` or `exec sleep`.** Just call `service_status` to check.
    - If `exec` returns "No such container", STOP trying to exec — fix the Dockerfile and rebuild.
    - **NEVER loop**: no `sleep && exec`, no retrying the same failing command.

    ## When things go wrong

    If the build fails, the container won't exist and every `exec` call returns "No such container".
    - Read the build error output (it's shown in the "Rebuild — failed" message). Fix the Dockerfile. Rebuild.
    - If you're stuck, ask the user for help rather than retrying endlessly.

    **When explaining problems to the user:** Boom Looper runs their project inside a Docker container, but the user may not know that. When something breaks because of the container environment, the abstraction has leaked. Your job is to:

    1. **Name the abstraction that leaked.** "Your project is running inside a Linux container. Your code is shared between your Mac and the container via a folder mount."
    2. **Explain why it matters for their specific problem.**
    3. **Tell them what you're doing to fix it** and what they'd need to know to fix it themselves.
    4. **If you can't fix it, give them enough context to search for a solution.**

    Don't hide Docker from them — just don't assume they know it's there.
    """
  end

  defp setup_prompt(bind_mount) do
    path_note = if bind_mount, do: " at #{bind_mount}", else: ""

    """
    ## Workspace Setup

    This is a new project#{path_note}. No workspace config exists yet.
    Examine the project files to understand what's needed. If the project already has a Dockerfile, read it and adapt it for dev — don't start from scratch.

    Use the workspace tools to configure step by step:
    1. `set_workspace_name` — name the project
    2. `set_dockerfile` — write a dev Dockerfile (install language, tools, system deps)
    3. `set_dev_command` — ONE command that starts the whole dev server (e.g. bin/dev, foreman start). Do NOT split Procfile entries into separate services — the Procfile runs INSIDE the dev container.
    4. `add_service` — add external services that need their own container (postgres, redis, etc.). NOT web servers, CSS watchers, or JS bundlers — those run inside the dev command.
    5. `set_env_vars` — set environment variables
    6. `set_system_prompt` — describe the project for future agents
    7. `rebuild` — build the Docker image
    8. `start_services` — boot everything up

    ## CRITICAL: The Dockerfile is a DEV image, not a production deploy

    The Dockerfile you write is for a DEVELOPMENT environment. The project directory is bind-mounted into the container at /workspace at RUNTIME — your code appears live in the container, edits on the host appear instantly.

    The Docker build context is the project root, so `COPY` works for dependency manifests. A good dev Dockerfile pattern:

    1. `FROM ruby:3.4` (or whatever language image)
    2. `RUN apt-get update && apt-get install -y <system packages>` (sqlite3, libpq-dev, etc.)
    3. `COPY Gemfile Gemfile.lock ./` then `RUN bundle install` — pre-installs deps in the image layer (fast rebuilds)
    4. `WORKDIR /workspace`

    **Do NOT `COPY . .`** — that copies the entire project into the image, which is pointless since it gets overlaid by the bind mount at runtime. Only copy dependency manifests (Gemfile, package.json, etc.) to pre-install deps.

    **After rebuild, use `exec` for runtime setup:**
    - `bin/rails db:setup` — create/migrate database
    - Any one-time setup commands that need the full project files

    ## CRITICAL: Library path clobbering

    The host project directory (macOS) is bind-mounted into the container (Linux) at /workspace. This creates a problem: if the project has compiled dependencies in a subdirectory (vendor/bundle, node_modules, _build, .venv, etc.), the host's macOS-compiled binaries will be visible inside the Linux container and will crash.

    **The principle:** Any directory that contains platform-specific compiled artifacts must be redirected to a path OUTSIDE /workspace. Use ENV vars in the Dockerfile to override the default install location.

    **How to figure this out for any project:**
    1. Read the project's dependency config files (.bundle/config, .npmrc, pip.conf, etc.)
    2. Check if deps are configured to install into a project subdirectory
    3. If yes, set an ENV var in the Dockerfile to redirect to a system path
    4. If the language's official Docker image already installs to a system path by default, just make sure no project config overrides it

    **Common examples** (but apply the principle to ANY language you encounter):
    - Ruby: check `.bundle/config` for `BUNDLE_PATH`. If it says `vendor/bundle`, override with `ENV BUNDLE_PATH=/usr/local/bundle`
    - Node: `node_modules` is always in the project dir. Running `npm install` inside the container will overwrite the host's copy with Linux versions — this is usually fine.
    - Python: check for `.venv` in project. Override with `ENV VIRTUAL_ENV=/opt/venv`

    **The key question to ask yourself:** "Does this language store compiled .so/.dylib files in a subdirectory of the project? If yes, where, and how do I redirect it?"
    """
  end

  defp checklist_prompt(checklist_path) do
    """

    ## Active Checklist

    You have an active checklist at #{checklist_path}.
    Work through each item in order. Use the `check_item` tool to mark items done as you complete them.
    Use the `get_progress` tool to see your current status.
    Do not skip items — complete them in sequence.
    """
  end

  # --- Tool Configuration ---

  defp default_tools do
    [BoomLooper.Tools.Agents, BoomLooper.Tools.Container, BoomLooper.Tools.Workspace, BoomLooper.Tools.Secrets, BoomLooper.Tools.Checklist]
  end

  defp build_mcp_servers(tool_modules) do
    Map.new(tool_modules, fn mod ->
      info = mod.__tool_server__()
      {info.name, mod}
    end)
  end

  defp build_allowed_tools(tool_modules) do
    Enum.flat_map(tool_modules, fn mod ->
      info = mod.__tool_server__()
      server_name = info.name

      Enum.map(info.tools, fn tool_mod ->
        "mcp__#{server_name}__#{tool_mod.__tool_name__()}"
      end)
    end)
  end
end
