defmodule BoomLooper.HostExposer do
  @moduledoc """
  Controls whether BoomLooper's web endpoint is reachable beyond localhost.

  The Phoenix endpoint defaults to `127.0.0.1`. When the operator toggles
  exposure on (via `/connect`), we rewrite the endpoint's `:ip` to
  `{0, 0, 0, 0}` and restart it. LiveView sessions reconnect automatically
  within ~1s.

  State persists in `~/.boomlooper/host_exposure.json` so the setting
  survives BEAM restarts.
  """

  use GenServer

  require Logger

  alias BoomLooper.EventLog

  @persist_file "host_exposure.json"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def exposed? do
    GenServer.call(__MODULE__, :exposed?)
  end

  def enable do
    GenServer.call(__MODULE__, :enable, 10_000)
  end

  def disable do
    GenServer.call(__MODULE__, :disable, 10_000)
  end

  def restore do
    GenServer.call(__MODULE__, :restore, 10_000)
  end

  # --- Callbacks ---

  @impl true
  def init(_opts) do
    {:ok, %{exposed: false}}
  end

  @impl true
  def handle_call(:exposed?, _from, state) do
    {:reply, state.exposed, state}
  end

  def handle_call(:enable, _from, state) do
    set_endpoint_ip({0, 0, 0, 0})
    restart_endpoint()
    persist(true)
    EventLog.info("host", "Exposed BoomLooper endpoint on 0.0.0.0")
    {:reply, :ok, %{state | exposed: true}}
  end

  def handle_call(:disable, _from, state) do
    set_endpoint_ip({127, 0, 0, 1})
    restart_endpoint()
    persist(false)
    EventLog.info("host", "Restricted BoomLooper endpoint to 127.0.0.1")
    {:reply, :ok, %{state | exposed: false}}
  end

  def handle_call(:restore, _from, state) do
    case load_persisted() do
      true ->
        set_endpoint_ip({0, 0, 0, 0})
        restart_endpoint()
        EventLog.info("host", "Restored exposed endpoint from previous session")
        {:reply, :ok, %{state | exposed: true}}

      false ->
        {:reply, :ok, state}
    end
  end

  # Catchalls — stray cast/call/info mustn't crash the endpoint-mode
  # toggle. handle_call catchall stays grouped with the specific
  # calls above.
  def handle_call(_msg, _from, state), do: {:reply, {:error, :unknown_call}, state}
  @impl true
  def handle_cast(_msg, state), do: {:noreply, state}
  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private ---

  defp set_endpoint_ip(ip) do
    current = Application.get_env(:boom_looper, BoomLooperWeb.Endpoint)
    http = Keyword.get(current, :http, [])
    http = Keyword.put(http, :ip, ip)
    updated = Keyword.put(current, :http, http)
    Application.put_env(:boom_looper, BoomLooperWeb.Endpoint, updated)
  end

  defp restart_endpoint do
    Supervisor.terminate_child(BoomLooper.Supervisor, BoomLooperWeb.Endpoint)
    Supervisor.restart_child(BoomLooper.Supervisor, BoomLooperWeb.Endpoint)
  end

  defp persist(exposed?) do
    path = persist_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(%{exposed: exposed?}))
  rescue
    e ->
      Logger.warning("[HostExposer] persist failed: #{Exception.message(e)}")
  end

  defp load_persisted do
    case File.read(persist_path()) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, %{"exposed" => true}} -> true
          _ -> false
        end

      _ ->
        false
    end
  end

  defp persist_path do
    home = Application.get_env(:boom_looper, :home) || Path.join(System.user_home!(), ".boomlooper")
    Path.join(home, @persist_file)
  end
end
