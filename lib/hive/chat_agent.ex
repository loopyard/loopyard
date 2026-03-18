defmodule Hive.ChatAgent do
  @moduledoc """
  GenServer wrapping a Claude Code SDK session.
  Streams structured messages to viewers via PubSub.
  Unlike the PTY-based Agent, this uses the JSON protocol
  for a proper multiplayer chat experience.
  """
  use GenServer, restart: :temporary
  require Logger

  alias Hive.Agent.Event

  defstruct [
    :id,
    :name,
    :session,
    :backend,
    :working_dir,
    :started_at,
    :started_by,
    :last_activity_at,
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
    GenServer.cast(via(id), :stop)
  end

  def rename(id, new_name) do
    GenServer.cast(via(id), {:rename, new_name})
  end

  @doc "Remove a stopped/crashed agent from the sidebar"
  def remove_agent(id) do
    ensure_ets_table()
    :ets.delete(@ets_table, id)
    broadcast(@topic, {:chat_agent_removed, id})
  end

  def list_agents do
    ensure_ets_table()

    :ets.tab2list(@ets_table)
    |> Enum.map(fn {_id, summary} ->
      # If agent is still alive, get fresh state
      case Registry.lookup(Hive.ChatAgentRegistry, summary.id) do
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
    Phoenix.PubSub.subscribe(Hive.PubSub, @topic)
  end

  def subscribe(agent_id) do
    Phoenix.PubSub.subscribe(Hive.PubSub, "chat_agent:#{agent_id}")
  end

  def unsubscribe(agent_id) do
    Phoenix.PubSub.unsubscribe(Hive.PubSub, "chat_agent:#{agent_id}")
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
    docker_ready = Keyword.get(opts, :docker_ready, false)

    # All agents are containerized. The async boot Task in ChatLive handles
    # container creation before starting this GenServer (docker_ready: true).
    # If docker_ready is false, create the container synchronously as fallback.
    unless docker_ready do
      docker_opts = Keyword.take(opts, [:dockerfile])
      docker_opts = if bind_mount, do: Keyword.put(docker_opts, :bind_mount, bind_mount), else: docker_opts

      case Hive.Docker.create(id, docker_opts) do
        {:ok, _} -> :ok
        {:error, reason} -> raise "Docker container failed: #{reason}"
      end
    end

    system_prompt = container_system_prompt(id, bind_mount)

    backend = Keyword.get(opts, :backend, Hive.Agent.Backend.ClaudeCode)

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
      backend: backend,
      working_dir: working_dir,
      started_at: now,
      started_by: started_by,
      last_activity_at: now,
      status: :idle,
      messages: []
    }

    summary = summary(state)
    :ets.insert(@ets_table, {id, summary})
    broadcast(@topic, {:chat_agent_started, summary})

    {:ok, state}
  end

  @impl true
  def handle_cast({:send_message, text}, state) do
    # Add user message
    user_msg = %{role: :user, content: text, timestamp: DateTime.utc_now()}
    state = %{state | messages: state.messages ++ [user_msg], status: :thinking}

    broadcast("chat_agent:#{state.id}", {:chat_message, state.id, user_msg})
    broadcast(@topic, {:chat_agent_status_changed, state.id, :thinking})

    # Stream the response in a Task linked to this GenServer
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
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_cast(:stop, state) do
    if state.session do
      state.backend.stop(state.session)
    end

    stopped = %{state | status: :stopped}
    :ets.insert(@ets_table, {state.id, summary(stopped)})
    broadcast(@topic, {:chat_agent_stopped, summary(stopped)})
    {:stop, :normal, stopped}
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
          state = %{state | messages: state.messages ++ [assistant_msg], last_activity_at: now}
          broadcast("chat_agent:#{id}", {:chat_message, id, assistant_msg})
          state

        %Event.ToolCall{name: tool_name, input: tool_input} ->
          tool_msg = %{role: :tool, tool: tool_name, input: tool_input, timestamp: now}
          state = %{state | messages: state.messages ++ [tool_msg], last_activity_at: now, tool_calls: state.tool_calls + 1}
          broadcast("chat_agent:#{id}", {:chat_message, id, tool_msg})
          state

        %Event.ToolResult{content: content, is_error: is_error} ->
          result_msg = %{role: :tool_result, content: content, is_error: is_error, timestamp: now}
          state = %{state | messages: state.messages ++ [result_msg], last_activity_at: now}
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
    now = DateTime.utc_now()
    error_msg = %{role: :error, content: reason, timestamp: now}
    state = %{state | messages: state.messages ++ [error_msg], status: :idle, last_activity_at: now, errors: state.errors + 1}
    broadcast("chat_agent:#{id}", {:chat_message, id, error_msg})
    broadcast(@topic, {:chat_agent_status_changed, id, :idle})
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

  defp via(id), do: {:via, Registry, {Hive.ChatAgentRegistry, id}}

  defp summary(state) do
    %{
      id: state.id,
      name: state.name,
      working_dir: state.working_dir,
      started_at: state.started_at,
      started_by: state.started_by,
      last_activity_at: state.last_activity_at,
      status: state.status,
      messages: state.messages,
      tool_calls: state.tool_calls,
      errors: state.errors
    }
  end

  defp broadcast(topic, message) do
    Phoenix.PubSub.broadcast(Hive.PubSub, topic, message)
  end

  # --- System Prompt ---

  defp container_system_prompt(agent_id, bind_mount) do
    container = Hive.Docker.container_name(agent_id)
    port = Hive.Docker.host_port(agent_id)

    workspace_info =
      if bind_mount do
        """
        - /workspace is a bind mount of #{bind_mount} — edits appear on the host immediately
        - Do NOT use `rebuild` — the workspace is a live bind mount, not a volume
        """
      else
        """
        - /workspace persists across rebuilds (it's a Docker volume)
        - The Dockerfile at /workspace/Dockerfile controls the container image — edit it to add system packages, languages, or databases, then rebuild
        """
      end

    """
    You have a running container "#{container}" with your workspace at /workspace.

    YOUR AGENT ID: #{agent_id}

    IMPORTANT: Use the hive-container MCP tools for ALL work. Pass your agent_id "#{agent_id}" to every container tool call.

    ## How to work

    - **Run commands**: Use `exec` to run shell commands inside your container
    - **Edit files**: Use `exec` with shell commands (cat, sed, tee, etc.) to read/write files in /workspace
    - **Install dependencies**: Use `exec` to run apt-get, npm, pip, etc. inside the container
    - **Run services**: Use `start_service` to launch background processes (web servers, databases). They log to /var/log/<name>.log
    - **Check status**: Use `logs` to see what's running, `ports` to see listeners, `inspect_env` for full environment info

    ## Container details

    - Host port #{port} maps to container port 3000 (for web servers)
    #{workspace_info}- /root/.cache persists (package caches)

    Do NOT use your local Bash/Read/Write tools for project work — everything goes through the container tools.
    """
  end

  # --- Tool Configuration ---

  defp default_tools do
    [Hive.Tools.Agents, Hive.Tools.Container]
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
