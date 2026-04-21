defmodule BoomLooper.PortRegistry do
  @moduledoc """
  Owns host-port allocation and proxy lifecycle for every workspace.

  Docker containers bind ephemeral loopback ports. This registry
  assigns stable user-facing ports from a global pool (4000..9999) and
  manages the PortExposer proxy that sits between users and Docker.

  ## Port lifecycle

  1. Compose processing calls `assign/3` → gets a sticky user-facing port
  2. Docker starts with an ephemeral loopback port (127.0.0.1::<cport>)
  3. Observer discovers Docker's port → `set_docker_port/4` stores it
     and starts the proxy: user_port → docker_port
  4. `set_exposure/4` toggles the proxy between 127.0.0.1 (private)
     and 0.0.0.0 (exposed)

  Reads from ETS are direct. Writes go through this GenServer to
  serialize the "lowest unused port" scan.
  """

  use GenServer

  alias BoomLooper.{EventLog, PortStore}

  @table :port_registry

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Assign a user-facing host port for `{workspace_id, service, container_port}`.
  Sticky: same triple always returns the same port.
  """
  def assign(workspace_id, service, container_port)
      when is_binary(workspace_id) and is_binary(service) and is_integer(container_port) do
    GenServer.call(__MODULE__, {:assign, workspace_id, service, container_port})
  end

  @doc """
  Store Docker's ephemeral port and start the proxy.
  Called by ServiceManager after compose up, once Observer reports
  the container's actual port mapping.
  """
  def set_docker_port(workspace_id, service, container_port, docker_port)
      when is_binary(workspace_id) and is_binary(service) and
             is_integer(container_port) and is_integer(docker_port) do
    GenServer.call(__MODULE__, {:set_docker_port, workspace_id, service, container_port, docker_port})
  end

  @doc """
  Toggle exposure. `true` = restart proxy on 0.0.0.0 (LAN reachable).
  `false` = restart proxy on 127.0.0.1 (localhost only).
  """
  def set_exposure(workspace_id, service, container_port, exposed?)
      when is_binary(workspace_id) and is_binary(service) and
             is_integer(container_port) and is_boolean(exposed?) do
    GenServer.call(__MODULE__, {:set_exposure, workspace_id, service, container_port, exposed?})
  end

  @doc "Lookup entry. Direct ETS read."
  def get(workspace_id, service, container_port) do
    case :ets.lookup(@table, {workspace_id, service, container_port}) do
      [{_, entry}] -> {:ok, entry}
      [] -> :none
    end
  end

  @doc "List entries for a workspace. Direct ETS read."
  def list_for_workspace(workspace_id) do
    :ets.tab2list(@table)
    |> Enum.filter(fn {{ws, _, _}, _} -> ws == workspace_id end)
    |> Enum.map(fn {_, entry} -> entry end)
  end

  @doc "Release all entries for a workspace. Stops any running proxies."
  def release_workspace(workspace_id) when is_binary(workspace_id) do
    GenServer.call(__MODULE__, {:release_workspace, workspace_id})
  end

  @doc "Load persisted entries from disk."
  def restore do
    GenServer.call(__MODULE__, :restore)
  end

  @doc "Reconfigure at runtime (for tests)."
  def configure(opts) when is_list(opts) do
    GenServer.call(__MODULE__, {:configure, opts})
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    persist = Keyword.get(opts, :persist, true)

    port_range =
      Keyword.get(opts, :port_range) ||
        (Application.get_env(:boom_looper, __MODULE__)[:port_range] || 4000..9999)

    BoomLooper.StateKeeper.ensure_tables!()

    {:ok, %{port_range: port_range, persist: persist, reserved: reserved_ports()}}
  end

  @impl true
  def handle_call({:assign, ws, svc, cport}, _from, state) do
    key = {ws, svc, cport}

    case :ets.lookup(@table, key) do
      [{^key, entry}] ->
        {:reply, {:ok, entry.host_port}, state}

      [] ->
        case find_free_port(state.port_range) do
          {:ok, host_port} ->
            entry = %{
              workspace_id: ws,
              service: svc,
              container_port: cport,
              host_port: host_port,
              docker_port: nil,
              exposed: false,
              allocated_at: DateTime.utc_now()
            }

            :ets.insert(@table, {key, entry})
            persist(state)
            EventLog.info("ports", "Assigned #{ws}/#{svc}/#{cport} → host #{host_port}")
            {:reply, {:ok, host_port}, state}

          {:error, :port_pool_exhausted} = err ->
            EventLog.error("ports", "Port pool exhausted for #{ws}/#{svc}/#{cport}")
            {:reply, err, state}
        end
    end
  end

  def handle_call({:set_docker_port, ws, svc, cport, docker_port}, _from, state) do
    key = {ws, svc, cport}

    case :ets.lookup(@table, key) do
      [] ->
        {:reply, {:error, :not_registered}, state}

      [{^key, entry}] ->
        # Stop old proxy if running (docker_port changed on restart)
        stop_proxy(key)

        updated = Map.put(entry, :docker_port, docker_port)
        :ets.insert(@table, {key, updated})
        persist(state)

        # Start proxy: private by default, exposed if flag is set
        bind_ip = if updated.exposed, do: {0, 0, 0, 0}, else: {127, 0, 0, 1}
        start_proxy(key, updated, bind_ip)

        EventLog.info("ports", "Proxy #{ws}/#{svc}/#{cport}: " <>
          "#{format_ip(bind_ip)}:#{updated.host_port} → 127.0.0.1:#{docker_port}")

        {:reply, :ok, state}
    end
  end

  def handle_call({:set_exposure, ws, svc, cport, exposed?}, _from, state) do
    key = {ws, svc, cport}

    case :ets.lookup(@table, key) do
      [] ->
        {:reply, {:error, :not_registered}, state}

      [{^key, entry}] when entry.exposed == exposed? ->
        {:reply, :ok, state}

      [{^key, %{docker_port: nil}}] ->
        # Can't expose if we don't know Docker's port yet
        {:reply, {:error, :no_docker_port}, state}

      [{^key, entry}] ->
        stop_proxy(key)
        bind_ip = if exposed?, do: {0, 0, 0, 0}, else: {127, 0, 0, 1}

        case start_proxy(key, entry, bind_ip) do
          :ok ->
            updated = %{entry | exposed: exposed?}
            :ets.insert(@table, {key, updated})
            persist(state)

            action = if exposed?, do: "Exposed", else: "Restricted"
            EventLog.info("ports", "#{action} #{ws}/#{svc}/#{cport} on #{format_ip(bind_ip)}:#{entry.host_port}")
            {:reply, :ok, state}

          {:error, reason} = err ->
            # Try to restart with the old binding so service isn't dead
            old_bind = if entry.exposed, do: {0, 0, 0, 0}, else: {127, 0, 0, 1}
            start_proxy(key, entry, old_bind)

            EventLog.error("ports", "Failed to toggle exposure for #{ws}/#{svc}/#{cport}: #{inspect(reason)}")
            {:reply, err, state}
        end
    end
  end

  def handle_call({:release_workspace, ws}, _from, state) do
    entries =
      :ets.tab2list(@table)
      |> Enum.filter(fn {{w, _, _}, _} -> w == ws end)

    for {key, _entry} <- entries do
      stop_proxy(key)
      :ets.delete(@table, key)
    end

    if entries != [] do
      EventLog.info("ports", "Released #{length(entries)} port(s) for workspace #{ws}")
      persist(state)
    end

    {:reply, :ok, state}
  end

  def handle_call({:configure, opts}, _from, state) do
    state =
      Enum.reduce(opts, state, fn
        {:port_range, range}, acc -> %{acc | port_range: range}
        {:persist, flag}, acc -> %{acc | persist: flag}
        _, acc -> acc
      end)

    {:reply, :ok, state}
  end

  def handle_call(:restore, _from, state) do
    if File.exists?(PortStore.path()) do
      for entry <- PortStore.load() do
        key = {entry.workspace_id, entry.service, entry.container_port}
        :ets.insert(@table, {key, entry})

        # If docker_port is known, restart the proxy
        if entry[:docker_port] do
          bind_ip = if entry.exposed, do: {0, 0, 0, 0}, else: {127, 0, 0, 1}

          case start_proxy(key, entry, bind_ip) do
            :ok -> :ok
            {:error, reason} ->
              require Logger
              Logger.warning("[PortRegistry] Could not start proxy for #{inspect(key)}: #{inspect(reason)}")
          end
        end
      end
    end

    {:reply, :ok, state}
  end

  # --- Private ---

  defp reserved_ports do
    endpoint_port =
      case Application.get_env(:boom_looper, BoomLooperWeb.Endpoint) do
        nil -> nil
        cfg -> get_in(cfg, [:http, :port])
      end

    [endpoint_port] |> Enum.reject(&is_nil/1) |> MapSet.new()
  end

  defp find_free_port(range) do
    taken =
      :ets.tab2list(@table)
      |> MapSet.new(fn {_, entry} -> entry.host_port end)
      |> MapSet.union(reserved_ports())

    first_free =
      Enum.find(range, fn port ->
        not MapSet.member?(taken, port) and port_os_free?(port)
      end)

    if first_free, do: {:ok, first_free}, else: {:error, :port_pool_exhausted}
  end

  defp port_os_free?(port) do
    case :gen_tcp.listen(port, [:binary, ip: {0, 0, 0, 0}, active: false]) do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        true

      {:error, _} ->
        false
    end
  end

  defp start_proxy(key, entry, bind_ip) do
    upstream_port = entry[:docker_port] || entry.host_port

    spec =
      {BoomLooper.PortExposer,
       key: key,
       host_port: entry.host_port,
       upstream_host: {127, 0, 0, 1},
       upstream_port: upstream_port,
       bind_ip: bind_ip}

    case DynamicSupervisor.start_child(BoomLooper.PortExposerSupervisor, spec) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp stop_proxy(key) do
    case BoomLooper.PortExposer.whereis(key) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(BoomLooper.PortExposerSupervisor, pid); :ok
    end
  end

  defp persist(%{persist: false}), do: :ok

  defp persist(%{persist: true, port_range: range}) do
    entries = :ets.tab2list(@table) |> Enum.map(fn {_, entry} -> entry end)
    PortStore.save(entries, range)
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
end
