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

  @doc "Store build log output as a message in the agent's ETS state"
  def update_build_log(id, content) do
    ensure_ets_table()
    case :ets.lookup(@ets_table, id) do
      [{^id, summary}] ->
        build_msg = %{role: :build, content: content, timestamp: DateTime.utc_now()}
        messages = summary.messages
        messages =
          if Enum.any?(messages, &(&1.role == :build)) do
            Enum.map(messages, fn
              %{role: :build} -> build_msg
              other -> other
            end)
          else
            messages ++ [build_msg]
          end
        :ets.insert(@ets_table, {id, %{summary | messages: messages}})
      [] -> :ok
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
    |> Enum.sort_by(& &1.started_at, {:desc, DateTime})
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
    id = Keyword.fetch!(opts, :id)
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

    broadcast("chat_agent:#{state.id}", {:chat_message, state.id, user_msg})

    # Don't try to stream if session is still dead
    unless state.backend.session_alive?(state.session) do
      broadcast(@topic, {:chat_agent_status_changed, state.id, :idle})
      {:noreply, state}
    else

    state = %{state | status: :thinking}
    broadcast(@topic, {:chat_agent_status_changed, state.id, :thinking})

    # Stream the response in a Task
    me = self()
    agent_id = state.id
    session = state.session
    backend = state.backend

    Task.start(fn ->
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
        broadcast("chat_agent:#{state.id}", {:chat_message, state.id, restart_msg})
        {:noreply, state}

      {:error, reason} ->
        error_msg = %{role: :error, content: "Failed to restart session: #{inspect(reason)}", timestamp: DateTime.utc_now()}
        state = %{append_message(state, error_msg) | errors: state.errors + 1}
        broadcast("chat_agent:#{state.id}", {:chat_message, state.id, error_msg})
        {:noreply, state}
    end
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
          broadcast("chat_agent:#{id}", {:chat_message, id, assistant_msg})
          state

        %Event.ToolCall{name: tool_name, input: tool_input} ->
          tool_msg = %{role: :tool, tool: tool_name, input: tool_input, timestamp: now}
          state = %{append_message(state, tool_msg) | last_activity_at: now, tool_calls: state.tool_calls + 1}
          broadcast("chat_agent:#{id}", {:chat_message, id, tool_msg})
          state

        %Event.ToolResult{content: content, is_error: is_error} ->
          result_msg = %{role: :tool_result, content: content, is_error: is_error, timestamp: now}
          state = %{append_message(state, result_msg) | last_activity_at: now}
          broadcast("chat_agent:#{id}", {:chat_message, id, result_msg})
          state

        %Event.TextDelta{text: text} ->
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
          broadcast("chat_agent:#{id}", {:chat_message, id, recovered_msg})
          broadcast(@topic, {:chat_agent_status_changed, id, :idle})
          {:noreply, state}

        {:error, _} ->
          fail_msg = %{role: :error, content: "Agent session crashed and failed to restart", timestamp: DateTime.utc_now()}
          state = %{append_message(state, fail_msg) | status: :idle}
          broadcast("chat_agent:#{id}", {:chat_message, id, fail_msg})
          broadcast(@topic, {:chat_agent_status_changed, id, :idle})
          {:noreply, state}
      end
    else
      error_msg = %{role: :error, content: reason, timestamp: now}
      state = %{append_message(state, error_msg) | status: :idle, last_activity_at: now, errors: state.errors + 1}
      broadcast("chat_agent:#{id}", {:chat_message, id, error_msg})
      broadcast(@topic, {:chat_agent_status_changed, id, :idle})
      {:noreply, state}
    end
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
      broadcast("chat_agent:#{state.id}", {:chat_message, state.id, restart_msg})
      state = append_message(state, restart_msg)

      case state.backend.start_session(state.session_opts) do
        {:ok, new_session} ->
          BoomLooper.EventLog.info("agent:#{state.name}", "CLI session restarted")
          ok_msg = %{role: :system, content: "Reconnected.", timestamp: DateTime.utc_now()}
          broadcast("chat_agent:#{state.id}", {:chat_message, state.id, ok_msg})
          append_message(%{state | session: new_session}, ok_msg)

        {:error, reason} ->
          BoomLooper.EventLog.error("agent:#{state.name}", "Failed to restart CLI: #{inspect(reason)}")
          fail_msg = %{role: :error, content: "Failed to reconnect: #{inspect(reason)}", timestamp: DateTime.utc_now()}
          broadcast("chat_agent:#{state.id}", {:chat_message, state.id, fail_msg})
          append_message(state, fail_msg)
      end
    end
  end

  defp append_message(state, msg) do
    %{state | messages: state.messages ++ [msg]}
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
        "boom-looper-ws-unknown"
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

    - **Run commands**: Use `exec` to run shell commands inside the workspace container
    - **Edit files**: Use `exec` with shell commands (cat, sed, tee, etc.) to read/write files in /workspace
    - **Install dependencies**: Use `exec` to run apt-get, mix, npm, pip, etc. inside the container
    - **Check status**: Use `logs` to see container output, `ports` to see listeners, `inspect_env` for full environment info
    - **Rebuild**: Use the `rebuild` workspace tool to rebuild the container image after changing the Dockerfile

    ## Container details

    - #{workspace_note}
    - /root/.cache persists (package caches)
    - The dev server runs in a SEPARATE container. To reach it from exec, use the container hostname (e.g. `curl http://boom-looper-ws-XXXX-dev:PORT/`)
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
