defmodule Hive.Agent do
  @moduledoc """
  GenServer wrapping a Claude Code CLI process.
  Streams raw stdio to/from the browser via PubSub.
  Uses ExPTY for proper PTY allocation with resize support.
  """
  use GenServer, restart: :temporary
  require Logger

  alias Hive.RingBuffer

  defstruct [
    :id,
    :name,
    :pty,
    :working_dir,
    :started_at,
    :started_by,
    :cols,
    :rows,
    status: :running,
    output: RingBuffer.new(),
    needs_attention: false
  ]

  # Patterns that indicate Claude is waiting for user input
  @attention_patterns [
    ~r/\(y\/n\)/,
    ~r/\(Y\/n\)/,
    ~r/\[Y\/n\]/,
    ~r/\[yes\/no\]/i,
    ~r/Allow\?/,
    ~r/Proceed\?/,
    ~r/\?\s*$/m
  ]

  # Patterns that indicate Claude is actively working (not waiting)
  @working_patterns [
    ~r/⠋|⠙|⠹|⠸|⠼|⠴|⠦|⠧|⠇|⠏/,
    ~r/\.\.\./
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

    # Use ExPTY for proper PTY with resize support
    me = self()

    {:ok, pty} =
      ExPTY.spawn(claude_path, [], [
        {:name, "xterm-256color"},
        {:cols, cols},
        {:rows, rows},
        {:cwd, working_dir},
        {:env, %{"TERM" => "xterm-256color", "COLUMNS" => "#{cols}", "LINES" => "#{rows}"}},
        {:on_data, fn _pty, _pid, data -> send(me, {:pty_data, data}) end},
        {:on_exit, fn _pty, _pid, exit_code, _signal -> send(me, {:pty_exit, exit_code}) end}
      ])

    state = %__MODULE__{
      id: id,
      name: name,
      pty: pty,
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
      ExPTY.write(state.pty, text <> "\n")
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:raw_input, data}, state) do
    if state.status == :running do
      ExPTY.write(state.pty, data)
    end

    # Clear attention flag when user sends input
    if state.needs_attention do
      broadcast(@topic, {:agent_attention_changed, state.id, false})
      {:noreply, %{state | needs_attention: false}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast(:stop, state) do
    if state.status == :running do
      ExPTY.write(state.pty, <<3>>)
      Process.send_after(self(), :force_close, 2000)
    end

    {:noreply, %{state | status: :stopping}}
  end

  @impl true
  def handle_cast(:kill, state) do
    ExPTY.kill(state.pty, 9)

    broadcast(@topic, {:agent_stopped, summary(%{state | status: :stopped})})
    {:stop, :normal, %{state | status: :stopped}}
  end

  @impl true
  def handle_cast({:resize, cols, rows}, %{status: :running} = state) do
    # Real PTY resize with SIGWINCH via ExPTY
    ExPTY.resize(state.pty, cols, rows)
    new_state = %{state | cols: cols, rows: rows}
    broadcast("agent:#{state.id}", {:agent_resized, state.id, cols, rows})
    {:noreply, new_state}
  end

  def handle_cast({:resize, _cols, _rows}, state), do: {:noreply, state}

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, summary(state), state}
  end

  # ExPTY data callback
  @impl true
  def handle_info({:pty_data, data}, state) do
    attention = detect_attention(data, state.needs_attention)
    new_state = %{state | output: RingBuffer.append(state.output, data), needs_attention: attention}

    broadcast("agent:#{state.id}", {:agent_output, state.id, data})

    if attention != state.needs_attention do
      broadcast(@topic, {:agent_attention_changed, state.id, attention})
    end

    {:noreply, new_state}
  end

  # ExPTY exit callback
  @impl true
  def handle_info({:pty_exit, code}, state) do
    new_state = %{state | status: {:exited, code}}
    broadcast(@topic, {:agent_stopped, summary(new_state)})
    broadcast("agent:#{state.id}", {:agent_exited, state.id, code})

    # Keep process alive so output is still viewable
    Process.send_after(self(), :cleanup, :timer.minutes(30))
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:force_close, %{status: :stopping} = state) do
    ExPTY.kill(state.pty, 9)

    broadcast(@topic, {:agent_stopped, summary(%{state | status: :stopped})})
    {:stop, :normal, %{state | status: :stopped}}
  end

  @impl true
  def handle_info(:force_close, state), do: {:noreply, state}

  @impl true
  def handle_info(:cleanup, state) do
    {:stop, :normal, state}
  end

  # Catch-all for any unexpected messages (e.g. old Port messages during transition)
  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private ---

  defp via(id), do: {:via, Registry, {Hive.AgentRegistry, id}}

  defp summary(state) do
    %{
      id: state.id,
      name: state.name,
      working_dir: state.working_dir,
      started_at: state.started_at,
      started_by: state.started_by,
      status: state.status,
      output: RingBuffer.to_binary(state.output),
      cols: state.cols,
      rows: state.rows,
      needs_attention: state.needs_attention
    }
  end

  defp broadcast(topic, message) do
    Phoenix.PubSub.broadcast(Hive.PubSub, topic, message)
  end

  # Strip ANSI escape sequences for pattern matching
  defp strip_ansi(data) do
    data
    |> String.replace(~r/\e\[[0-9;]*[a-zA-Z]/, "")
    |> String.replace(~r/\e\][^\a]*\a/, "")
  end

  defp detect_attention(data, _prev_attention) do
    clean = strip_ansi(data)

    is_working = Enum.any?(@working_patterns, &Regex.match?(&1, clean))

    if is_working do
      false
    else
      Enum.any?(@attention_patterns, &Regex.match?(&1, clean))
    end
  end
end
