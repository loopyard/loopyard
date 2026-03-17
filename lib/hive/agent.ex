defmodule Hive.Agent do
  @moduledoc """
  GenServer wrapping a Claude Code CLI process.
  Streams raw stdio to/from the browser via PubSub.
  Uses `script` to allocate a PTY so Claude runs in interactive mode.
  """
  use GenServer, restart: :temporary
  require Logger

  alias Hive.RingBuffer

  defstruct [
    :id,
    :name,
    :port,
    :os_pid,
    :working_dir,
    :started_at,
    :started_by,
    :cols,
    :rows,
    status: :running,
    output: RingBuffer.new()
  ]

  @default_cols 120
  @default_rows 40
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

  def resize(id, cols, rows) do
    GenServer.cast(via(id), {:resize, cols, rows})
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

  @doc """
  Validates that the given working directory exists and is a directory.
  """
  def validate_working_dir(path) do
    case File.stat(path) do
      {:ok, %{type: :directory}} -> :ok
      {:ok, _} -> {:error, "Path exists but is not a directory"}
      {:error, :enoent} -> {:error, "Directory does not exist"}
      {:error, reason} -> {:error, "Cannot access directory: #{reason}"}
    end
  end

  def subscribe do
    Phoenix.PubSub.subscribe(Hive.PubSub, @topic)
  end

  def subscribe(agent_id) do
    Phoenix.PubSub.subscribe(Hive.PubSub, "agent:#{agent_id}")
  end

  def unsubscribe(agent_id) do
    Phoenix.PubSub.unsubscribe(Hive.PubSub, "agent:#{agent_id}")
  end

  # --- Callbacks ---

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    name = Keyword.get(opts, :name, "Agent #{id |> String.slice(0..7)}")
    working_dir = Keyword.get(opts, :working_dir, File.cwd!())
    started_by = Keyword.get(opts, :started_by, "anonymous")
    cols = Keyword.get(opts, :cols, @default_cols)
    rows = Keyword.get(opts, :rows, @default_rows)

    # Validate working directory
    case validate_working_dir(working_dir) do
      :ok -> :ok
      {:error, reason} -> raise "Invalid working directory #{working_dir}: #{reason}"
    end

    claude_path = System.find_executable("claude") || raise "claude CLI not found in PATH"
    {script_path, script_args} = Hive.PTY.wrap_command(claude_path)

    port =
      Port.open({:spawn_executable, script_path}, [
        :binary,
        :exit_status,
        :use_stdio,
        {:args, script_args},
        {:cd, working_dir},
        {:env, Hive.PTY.terminal_env(cols, rows)}
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
      output: RingBuffer.new(),
      cols: cols,
      rows: rows
    }

    broadcast(@topic, {:agent_started, summary(state)})

    {:ok, state}
  end

  @impl true
  def handle_cast({:input, text}, state) do
    if state.status == :running do
      Port.command(state.port, text <> "\n")
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:raw_input, data}, state) do
    if state.status == :running do
      Port.command(state.port, data)
    end

    {:noreply, state}
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
    kill_process_tree(state.os_pid)

    if state.port do
      try do
        Port.close(state.port)
      catch
        _, _ -> :ok
      end
    end

    broadcast(@topic, {:agent_stopped, summary(%{state | status: :stopped})})
    {:stop, :normal, %{state | status: :stopped}}
  end

  @impl true
  def handle_cast({:resize, cols, rows}, %{status: :running} = state) do
    # Send SIGWINCH-style resize by updating stty on the PTY
    # We can't directly resize the script PTY, but we can update env for new processes
    # For now, broadcast the new size to all viewers
    new_state = %{state | cols: cols, rows: rows}
    broadcast("agent:#{state.id}", {:agent_resized, state.id, cols, rows})
    {:noreply, new_state}
  end

  def handle_cast({:resize, _cols, _rows}, state), do: {:noreply, state}

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, summary(state), state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    new_state = %{state | output: RingBuffer.append(state.output, data)}
    broadcast("agent:#{state.id}", {:agent_output, state.id, data})
    {:noreply, new_state}
  end

  @impl true
  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    new_state = %{state | status: {:exited, code}}
    broadcast(@topic, {:agent_stopped, summary(new_state)})
    broadcast("agent:#{state.id}", {:agent_exited, state.id, code})

    # Keep process alive so output is still viewable
    Process.send_after(self(), :cleanup, :timer.minutes(30))
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:force_close, %{status: :stopping} = state) do
    kill_process_tree(state.os_pid)

    if state.port do
      try do
        Port.close(state.port)
      catch
        _, _ -> :ok
      end
    end

    broadcast(@topic, {:agent_stopped, summary(%{state | status: :stopped})})
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
      output: RingBuffer.to_binary(state.output),
      cols: state.cols,
      rows: state.rows
    }
  end

  defp broadcast(topic, message) do
    Phoenix.PubSub.broadcast(Hive.PubSub, topic, message)
  end

  @doc false
  def kill_process_tree(nil), do: :ok

  def kill_process_tree(pid) do
    pid_str = to_string(pid)

    # First try to kill the entire process group
    case System.cmd("kill", ["-9", "-#{pid_str}"], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      _ ->
        # Fallback: find and kill child processes, then the parent
        case System.cmd("pgrep", ["-P", pid_str], stderr_to_stdout: true) do
          {output, 0} ->
            output
            |> String.split("\n", trim: true)
            |> Enum.each(fn child_pid ->
              System.cmd("kill", ["-9", child_pid], stderr_to_stdout: true)
            end)

          _ ->
            :ok
        end

        System.cmd("kill", ["-9", pid_str], stderr_to_stdout: true)
    end

    :ok
  end
end
