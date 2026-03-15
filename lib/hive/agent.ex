defmodule Hive.Agent do
  @moduledoc """
  GenServer wrapping a Claude Code CLI process.
  Streams raw stdio to/from the browser via PubSub.
  Uses `script` to allocate a PTY so Claude runs in interactive mode.
  """
  use GenServer, restart: :temporary
  require Logger

  defstruct [
    :id,
    :name,
    :port,
    :os_pid,
    :working_dir,
    :started_at,
    :started_by,
    status: :running,
    output: ""
  ]

  @topic "agents"

  # --- Public API ---

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: via(id))
  end

  def send_input(id, text) do
    GenServer.cast(via(id), {:input, text})
  end

  def get_state(id) do
    GenServer.call(via(id), :get_state)
  end

  def send_raw(id, data) do
    GenServer.cast(via(id), {:raw_input, data})
  end

  def stop_agent(id) do
    GenServer.cast(via(id), :stop)
  end

  def kill_agent(id) do
    GenServer.cast(via(id), :kill)
  end

  def list_agents do
    Registry.select(Hive.AgentRegistry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}])
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
    Phoenix.PubSub.subscribe(Hive.PubSub, "agent:#{agent_id}")
  end

  # --- Callbacks ---

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    name = Keyword.get(opts, :name, "Agent #{id |> String.slice(0..7)}")
    working_dir = Keyword.get(opts, :working_dir, File.cwd!())
    started_by = Keyword.get(opts, :started_by, "anonymous")

    claude_path = System.find_executable("claude") || raise "claude CLI not found in PATH"
    script_path = System.find_executable("script") || raise "script not found in PATH"

    # Use `script` to give claude a PTY so it runs interactively
    # macOS `script` syntax: script -q /dev/null command [args...]
    port =
      Port.open({:spawn_executable, script_path}, [
        :binary,
        :exit_status,
        :use_stdio,
        {:args, ["-q", "/dev/null", claude_path]},
        {:cd, working_dir},
        {:env, [{~c"TERM", ~c"xterm-256color"}, {~c"COLUMNS", ~c"120"}, {~c"LINES", ~c"40"}]}
      ])

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    state = %__MODULE__{
      id: id,
      name: name,
      port: port,
      os_pid: os_pid,
      working_dir: working_dir,
      started_at: DateTime.utc_now(),
      started_by: started_by,
      status: :running,
      output: ""
    }

    broadcast(@topic, {:agent_started, summary(state)})

    {:ok, state}
  end

  @impl true
  def handle_cast({:input, text}, state) do
    if state.status == :running do
      Port.command(state.port, text <> "\n")
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:raw_input, data}, state) do
    if state.status == :running do
      Port.command(state.port, data)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast(:stop, state) do
    if state.status == :running do
      Port.command(state.port, <<3>>)
      Process.send_after(self(), :force_close, 2000)
    end

    {:noreply, %{state | status: :stopping}}
  end

  @impl true
  def handle_cast(:kill, state) do
    if state.os_pid do
      System.cmd("kill", ["-9", to_string(state.os_pid)])
    end

    if state.port do
      try do
        Port.close(state.port)
      catch
        _, _ -> :ok
      end
    end

    {:stop, :normal, %{state | status: :stopped}}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, summary(state), state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    new_state = %{state | output: state.output <> data}
    broadcast("agent:#{state.id}", {:agent_output, state.id, data})
    {:noreply, new_state}
  end

  @impl true
  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    new_state = %{state | status: {:exited, code}}
    broadcast(@topic, {:agent_stopped, summary(new_state)})
    broadcast("agent:#{state.id}", {:agent_exited, state.id, code})

    # Keep process alive so output is still viewable
    Process.send_after(self(), :cleanup, :timer.minutes(10))
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:force_close, %{status: :stopping} = state) do
    if state.port, do: Port.close(state.port)
    {:stop, :normal, %{state | status: :stopped}}
  end

  @impl true
  def handle_info(:force_close, state), do: {:noreply, state}

  @impl true
  def handle_info(:cleanup, state) do
    {:stop, :normal, state}
  end

  # --- Private ---

  defp via(id), do: {:via, Registry, {Hive.AgentRegistry, id}}

  defp summary(state) do
    %{
      id: state.id,
      name: state.name,
      os_pid: state.os_pid,
      working_dir: state.working_dir,
      started_at: state.started_at,
      started_by: state.started_by,
      status: state.status,
      output: state.output
    }
  end

  defp broadcast(topic, message) do
    Phoenix.PubSub.broadcast(Hive.PubSub, topic, message)
  end
end
