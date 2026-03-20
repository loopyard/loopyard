defmodule BoomLooper.Terminal do
  @moduledoc """
  GenServer wrapping a Port to `docker exec -it`. One per active console session.
  Broadcasts output via PubSub. Shared session — all viewers see the same terminal.
  """
  use GenServer
  require Logger

  @registry BoomLooper.TerminalRegistry

  def start_link(opts) do
    container = Keyword.fetch!(opts, :container)
    GenServer.start_link(__MODULE__, opts, name: via(container))
  end

  @doc "Get or start a terminal session for a container."
  def get_or_start(container) do
    case Registry.lookup(@registry, container) do
      [{pid, _}] -> {:ok, pid}
      [] ->
        DynamicSupervisor.start_child(BoomLooper.TerminalSupervisor,
          {__MODULE__, container: container})
    end
  end

  @doc "Send input (keystrokes) to the terminal."
  def send_input(container, data) do
    case Registry.lookup(@registry, container) do
      [{pid, _}] -> GenServer.cast(pid, {:input, data})
      [] -> {:error, :not_running}
    end
  end

  @doc "Resize the terminal."
  def resize(container, cols, rows) do
    case Registry.lookup(@registry, container) do
      [{pid, _}] -> GenServer.cast(pid, {:resize, cols, rows})
      [] -> :ok
    end
  end

  @doc "Get the output buffer for late joiners."
  def get_buffer(container) do
    case Registry.lookup(@registry, container) do
      [{pid, _}] -> GenServer.call(pid, :get_buffer)
      [] -> ""
    end
  end

  def topic(container), do: "terminal:#{container}"

  # --- Callbacks ---

  @impl true
  def init(opts) do
    container = Keyword.fetch!(opts, :container)

    # Check if container is running
    unless BoomLooper.Docker.container_running?(container) do
      {:stop, :container_not_running}
    else
      port = Port.open(
        {:spawn_executable, System.find_executable("docker")},
        [:binary, :exit_status, {:args, ["exec", "-it", container, "/bin/sh", "-l"]}]
      )

      {:ok, %{
        container: container,
        port: port,
        buffer: ""
      }}
    end
  end

  @impl true
  def handle_cast({:input, data}, state) do
    Port.command(state.port, data)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:resize, cols, rows}, state) do
    # Docker doesn't support resize via exec easily, but we can try
    # via the Docker API. For now, just store it.
    # TODO: implement resize via Docker API
    _ = {cols, rows}
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_buffer, _from, state) do
    {:reply, state.buffer, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    # Broadcast output to all subscribers
    Phoenix.PubSub.broadcast(BoomLooper.PubSub, topic(state.container), {:terminal_output, data})

    # Keep last 50KB of output for late joiners
    buffer = state.buffer <> data
    buffer = if byte_size(buffer) > 50_000, do: String.slice(buffer, -50_000..-1//1), else: buffer

    {:noreply, %{state | buffer: buffer}}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    Logger.info("[Terminal] #{state.container} exited with code #{code}")
    Phoenix.PubSub.broadcast(BoomLooper.PubSub, topic(state.container), {:terminal_exit, code})
    {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if Port.info(state.port), do: Port.close(state.port)
    :ok
  end

  defp via(container), do: {:via, Registry, {@registry, container}}
end
