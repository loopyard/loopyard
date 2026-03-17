defmodule Hive.ChatAgent do
  @moduledoc """
  GenServer wrapping a Claude Code SDK session.
  Streams structured messages to viewers via PubSub.
  Unlike the PTY-based Agent, this uses the JSON protocol
  for a proper multiplayer chat experience.
  """
  use GenServer, restart: :temporary
  require Logger

  defstruct [
    :id,
    :name,
    :session,
    :working_dir,
    :started_at,
    :started_by,
    status: :idle,
    messages: []
  ]

  @topic "chat_agents"

  # --- Public API ---

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: via(id))
  end

  def send_message(id, text) do
    GenServer.cast(via(id), {:send_message, text})
  end

  def get_state(id) do
    GenServer.call(via(id), :get_state)
  end

  def stop_agent(id) do
    GenServer.cast(via(id), :stop)
  end

  def rename(id, new_name) do
    GenServer.cast(via(id), {:rename, new_name})
  end

  def list_agents do
    Registry.select(Hive.ChatAgentRegistry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.map(fn {_id, pid} ->
      try do
        GenServer.call(pid, :get_state, 2000)
      catch
        :exit, _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
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
    use_docker = Keyword.get(opts, :docker, false)

    # If Docker mode, create container and use CLI wrapper
    docker_opts =
      if use_docker do
        case Hive.Docker.create(id, Keyword.take(opts, [:dockerfile])) do
          {:ok, _} ->
            [cli_path: Hive.Docker.cli_wrapper_path(id)]
          {:error, reason} ->
            raise "Docker container failed: #{reason}"
        end
      else
        []
      end

    session_opts =
      [
        cwd: working_dir,
        permission_mode: :accept_edits,
        dangerously_skip_permissions: true,
        mcp_servers: build_mcp_servers(tools),
        allowed_tools: build_allowed_tools(tools)
      ] ++ docker_opts

    session_opts =
      case Keyword.get(opts, :system_prompt) do
        nil -> session_opts
        "" -> session_opts
        prompt -> Keyword.put(session_opts, :system_prompt, prompt)
      end

    {:ok, session} = ClaudeCode.start_link(session_opts)

    state = %__MODULE__{
      id: id,
      name: name,
      session: session,
      working_dir: working_dir,
      started_at: DateTime.utc_now(),
      started_by: started_by,
      status: :idle,
      messages: []
    }

    broadcast(@topic, {:chat_agent_started, summary(state)})

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

    Task.start_link(fn ->
      try do
        session
        |> ClaudeCode.stream(text)
        |> Enum.each(fn msg ->
          send(me, {:stream_event, agent_id, msg})
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
      ClaudeCode.stop(state.session)
    end

    broadcast(@topic, {:chat_agent_stopped, summary(%{state | status: :stopped})})
    {:stop, :normal, %{state | status: :stopped}}
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
  def handle_info({:stream_event, id, msg}, %{id: id} = state) do
    case classify_message(msg) do
      {:assistant_message, content} ->
        assistant_msg = %{role: :assistant, content: content, timestamp: DateTime.utc_now()}
        state = %{state | messages: state.messages ++ [assistant_msg]}
        broadcast("chat_agent:#{id}", {:chat_message, id, assistant_msg})
        {:noreply, state}

      {:tool_use, tool_name, tool_input} ->
        tool_msg = %{role: :tool, tool: tool_name, input: tool_input, timestamp: DateTime.utc_now()}
        state = %{state | messages: state.messages ++ [tool_msg]}
        broadcast("chat_agent:#{id}", {:chat_message, id, tool_msg})
        {:noreply, state}

      :ignored ->
        {:noreply, state}
    end
  end

  def handle_info({:stream_done, id}, %{id: id} = state) do
    state = %{state | status: :idle}
    broadcast(@topic, {:chat_agent_status_changed, id, :idle})
    {:noreply, state}
  end

  def handle_info({:stream_error, id, reason}, %{id: id} = state) do
    error_msg = %{role: :error, content: reason, timestamp: DateTime.utc_now()}
    state = %{state | messages: state.messages ++ [error_msg], status: :idle}
    broadcast("chat_agent:#{id}", {:chat_message, id, error_msg})
    broadcast(@topic, {:chat_agent_status_changed, id, :idle})
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private ---

  defp via(id), do: {:via, Registry, {Hive.ChatAgentRegistry, id}}

  defp summary(state) do
    %{
      id: state.id,
      name: state.name,
      working_dir: state.working_dir,
      started_at: state.started_at,
      started_by: state.started_by,
      status: state.status,
      messages: state.messages
    }
  end

  defp broadcast(topic, message) do
    Phoenix.PubSub.broadcast(Hive.PubSub, topic, message)
  end

  # Classify SDK messages into simple categories for the UI
  defp classify_message(%ClaudeCode.Message.AssistantMessage{message: message}) do
    content = message.content || []

    text =
      content
      |> Enum.filter(&match?(%ClaudeCode.Content.TextBlock{}, &1))
      |> Enum.map_join("", & &1.text)

    tool_uses =
      content
      |> Enum.filter(&match?(%ClaudeCode.Content.ToolUseBlock{}, &1))

    cond do
      text != "" ->
        {:assistant_message, text}

      tool_uses != [] ->
        tool = hd(tool_uses)
        {:tool_use, tool.name, tool.input}

      true ->
        :ignored
    end
  end

  # ResultMessage is a summary of the full turn — the text is already
  # in the AssistantMessage, so we skip it to avoid duplicates.
  defp classify_message(%ClaudeCode.Message.ResultMessage{}), do: :ignored

  defp classify_message(_), do: :ignored

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
