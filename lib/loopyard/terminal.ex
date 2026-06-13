defmodule Loopyard.Terminal do
  @moduledoc """
  GenServer wrapping a Port for interactive terminal sessions.
  Broadcasts output via PubSub. Shared session — all viewers see the same terminal.
  """
  use GenServer
  require Logger

  alias Loopyard.RegistryHelper
  @registry Loopyard.TerminalRegistry

  def start_link(opts) do
    container = Keyword.fetch!(opts, :container)
    GenServer.start_link(__MODULE__, opts, name: via(container))
  end

  @doc "Get or start a terminal session for a container."
  def get_or_start(container) do
    case RegistryHelper.whereis(@registry, container) do
      {:ok, pid} ->
        {:ok, pid}

      :error ->
        DynamicSupervisor.start_child(
          Loopyard.TerminalSupervisor,
          {__MODULE__, container: container}
        )
    end
  end

  @doc "Stop a terminal session (so a fresh `docker exec` starts on next join)."
  def stop(container) do
    case RegistryHelper.whereis(@registry, container) do
      {:ok, pid} -> DynamicSupervisor.terminate_child(Loopyard.TerminalSupervisor, pid)
      :error -> :ok
    end
  end

  @doc "Send input (keystrokes) to the terminal."
  def send_input(container, data) do
    case RegistryHelper.whereis(@registry, container) do
      {:ok, pid} -> GenServer.cast(pid, {:input, data})
      :error -> {:error, :not_running}
    end
  end

  @doc "Resize the terminal."
  def resize(container, cols, rows) do
    RegistryHelper.cast(@registry, container, {:resize, cols, rows})
  end

  @doc "Get the output buffer for late joiners."
  def get_buffer(container) do
    case RegistryHelper.call(@registry, container, :get_buffer) do
      {:ok, buffer} -> buffer
      {:error, :not_found} -> ""
    end
  end

  @doc "Clear the buffer and broadcast clear to all viewers."
  def clear_buffer(container) do
    RegistryHelper.cast(@registry, container, :clear)
  end

  @doc "PubSub topic for terminal output. Distinct from the channel topic
  to avoid Phoenix transport subscriptions causing double delivery."
  def topic(container), do: "terminal_output:#{container}"

  @doc """
  Build the {executable, args} tuple for launching a terminal session
  inside a Docker container.

  Uses `script(1)` to allocate a PTY so interactive shells work.
  Disables local echo via `stty -echo` to prevent double-echo.
  Uses `docker exec -i` (not -it) — script provides the PTY, docker
  doesn't need to allocate a second one.
  """
  def build_cmd(container) do
    docker = System.find_executable("docker")
    script = System.find_executable("script")

    if script do
      # script allocates a PTY so docker exec -it works (Erlang Ports
      # don't provide one). The container's shell handles echo and line
      # editing via its own TTY (-t flag). The JS-side activeTerminals
      # dedup prevents double-output from stale reconnections.
      case :os.type() do
        {:unix, :darwin} ->
          {script, ["-q", "/dev/null", docker, "exec", "-it", container, "sh"]}

        _ ->
          {script, ["-qc", "#{docker} exec -it #{container} sh", "/dev/null"]}
      end
    else
      {docker, ["exec", "-i", container, "sh"]}
    end
  end

  @doc """
  Open a Port with the given {executable, args} command.
  Extracted so tests can verify port behavior independently.
  """
  def open_port({executable, args}) do
    Port.open(
      {:spawn_executable, executable},
      [:binary, :exit_status, {:args, args}]
    )
  end

  # --- Callbacks ---

  @impl true
  def init(opts) do
    container = Keyword.fetch!(opts, :container)

    # Allow tests to inject a custom command
    cmd = Keyword.get(opts, :cmd)

    cmd =
      cmd ||
        if Loopyard.Docker.container_running?(container) do
          build_cmd(container)
        end

    unless cmd do
      {:stop, :container_not_running}
    else
      port = open_port(cmd)

      {:ok,
       %{
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
  def handle_cast(:clear, state) do
    Loopyard.Events.Terminal.publish(%Loopyard.Events.Terminal.Clear{
      container: state.container
    })

    {:noreply, %{state | buffer: ""}}
  end

  @impl true
  def handle_cast({:resize, cols, rows}, state) do
    _ = {cols, rows}
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_buffer, _from, state) do
    {:reply, state.buffer, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    Loopyard.Events.Terminal.publish(%Loopyard.Events.Terminal.Output{
      container: state.container,
      data: data
    })

    buffer = state.buffer <> data
    buffer = if byte_size(buffer) > 50_000, do: String.slice(buffer, -50_000..-1//1), else: buffer

    {:noreply, %{state | buffer: buffer}}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    Logger.info("[Terminal] #{state.container} exited with code #{code}")

    Loopyard.Events.Terminal.publish(%Loopyard.Events.Terminal.Exit{
      container: state.container,
      code: code
    })

    {:stop, :normal, state}
  end

  def handle_info(msg, state) do
    Logger.warning(
      "[Terminal] container=#{state.container} unhandled: #{inspect(msg, limit: 200)}"
    )

    :telemetry.execute(
      [:loopyard, :actor, :unknown_message],
      %{count: 1},
      %{actor: __MODULE__, container: state.container, msg: inspect(msg, limit: 200)}
    )

    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if Port.info(state.port), do: Port.close(state.port)
    :ok
  end

  defp via(container), do: {:via, Registry, {@registry, container}}
end
