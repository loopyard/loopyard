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

    # Subscribe to Docker state changes so we can start/stop proxies
    # as containers come up and go down.
    Phoenix.PubSub.subscribe(BoomLooper.PubSub, "docker_observer")

    {:ok, %{
      port_range: port_range,
      persist: persist,
      reserved: reserved_ports(),
      last_reconcile: 0  # monotonic ms — debounce reconciler
    }}
  end

  @impl true
  def handle_call({:assign, ws, svc, cport}, _from, state) do
    key = {ws, svc, cport}

    case :ets.lookup(@table, key) do
      [{^key, entry}] ->
        # Re-track on existing entries too — the workspace supervisor pid
        # may have changed (restart) since the original assign. Resources
        # is idempotent under the same {kind, id} + same owner; under a
        # new owner it returns {:error, :already_tracked} which we ignore
        # because the original owner's release would still fire.
        track_binding(ws, svc, cport)
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
            track_binding(ws, svc, cport)
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
            updated = Map.merge(entry, %{exposed: exposed?, transitioning: false})
            :ets.insert(@table, {key, updated})
            persist(state)

            action = if exposed?, do: "Opened", else: "Closed"
            EventLog.info("ports", "#{action} #{ws}/#{svc}/#{cport} on #{format_ip(bind_ip)}:#{entry.host_port}")
            {:reply, :ok, state}

          {:error, reason} = err ->
            # Clear transitioning so the reconciler can recover this entry
            :ets.insert(@table, {key, Map.put(entry, :transitioning, false)})

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
      # Untrack from Resources too, so a later supervisor DOWN doesn't
      # invoke release_binding on an already-released entry. Safe to
      # call whether or not the resource was tracked — Resources.release
      # is a no-op for unknown {kind, id} pairs.
      BoomLooper.Resources.release(:port_binding, key)
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
        # Clear docker_port on restore — Docker may have assigned a
        # different ephemeral port while we were down. The reconciler
        # will rediscover the actual port from Observer on the next
        # docker_state_changed event.
        cleaned = Map.put(entry, :docker_port, nil)
        :ets.insert(@table, {key, cleaned})
      end
    end

    {:reply, :ok, state}
  end

  # --- Docker lifecycle: start/stop proxies as containers change ---

  @impl true
  def handle_info(%{__struct__: BoomLooper.Events.DockerObserver.Changed}, state) do
    # Debounce: skip if we reconciled within the last second. Docker
    # events come in bursts (container start emits create + start +
    # attach + ...). Without debounce, a container crash-loop would
    # churn proxies on every event.
    now = System.monotonic_time(:millisecond)

    if now - state.last_reconcile > 1_000 do
      reconcile_proxies(state)
      {:noreply, %{state | last_reconcile: now, reconcile_scheduled: false}}
    else
      # Schedule ONE catch-up so we don't miss the final state
      unless state[:reconcile_scheduled] do
        Process.send_after(self(), :deferred_reconcile, 1_100)
      end

      {:noreply, Map.put(state, :reconcile_scheduled, true)}
    end
  end

  def handle_info(:deferred_reconcile, state) do
    reconcile_proxies(state)
    {:noreply, %{state | last_reconcile: System.monotonic_time(:millisecond), reconcile_scheduled: false}}
  end

  def handle_info(%{__struct__: BoomLooper.Events.DockerObserver.Reset}, state) do
    # Docker disconnected — stop all proxies since we can't reach upstream
    stop_all_proxies()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private ---

  # Track this binding under the workspace-supervisor pid so the
  # Resources janitor releases it when the supervisor goes DOWN. No-op
  # if no group is registered (typical during early-boot reconnect).
  defp track_binding(ws, svc, cport) do
    case Registry.lookup(BoomLooper.WorkspaceRegistry, ws) do
      [{owner_pid, _}] ->
        BoomLooper.Resources.track(
          owner_pid,
          :port_binding,
          {ws, svc, cport},
          fn -> release_binding(ws, svc, cport) end
        )

      _ ->
        :ok
    end
  end

  # Release a single binding. Used as the Resources release_fn — invoked
  # either when the workspace supervisor goes DOWN or when an explicit
  # release path (release_workspace/1) calls Resources.release for each
  # entry. Side effects only; no Resources.release call here (we'd loop).
  defp release_binding(ws, svc, cport) do
    key = {ws, svc, cport}
    stop_proxy(key)
    :ets.delete(@table, key)
    EventLog.info("ports", "Released binding #{ws}/#{svc}/#{cport}")
    :ok
  end

  # Walk every registry entry and reconcile proxy state with Docker:
  # - Container up + port changed → update docker_port + restart proxy
  # - Container up + proxy not running → start proxy
  # - Container down + proxy running → stop proxy
  defp reconcile_proxies(state) do
    entries = :ets.tab2list(@table) |> Enum.map(fn {_, e} -> e end)
    # Group by workspace to minimize Observer lookups
    by_ws = Enum.group_by(entries, & &1.workspace_id)

    for {ws_id, ws_entries} <- by_ws do
      project_name = BoomLooper.Compose.project_name(ws_id)
      containers = BoomLooper.Docker.Observer.containers_for(ws_id)

      for entry <- ws_entries, !entry[:transitioning] do
        key = {ws_id, entry.service, entry.container_port}
        container_name = "#{project_name}-#{entry.service}-1"
        container = Enum.find(containers, &(&1.name == container_name))
        container_running? = container && container.running

        docker_port =
          if container && container[:host_ports] do
            raw = container.host_ports[entry.container_port] ||
                  container.host_ports[to_string(entry.container_port)]
            if raw, do: (if is_binary(raw), do: String.to_integer(raw), else: raw)
          end

        proxy_running? = BoomLooper.PortExposer.whereis(key) != nil

        cond do
          # Container running, port known, proxy needs start or update
          container_running? && docker_port && docker_port != entry[:docker_port] ->
            stop_proxy(key)
            updated = Map.put(entry, :docker_port, docker_port)
            :ets.insert(@table, {key, updated})
            bind_ip = if updated.exposed, do: {0, 0, 0, 0}, else: {127, 0, 0, 1}
            start_proxy(key, updated, bind_ip)
            persist(state)

          container_running? && docker_port && !proxy_running? ->
            bind_ip = if entry.exposed, do: {0, 0, 0, 0}, else: {127, 0, 0, 1}
            start_proxy(key, entry, bind_ip)

          # Container down, proxy still running → stop it
          !container_running? && proxy_running? ->
            stop_proxy(key)

          true ->
            :ok
        end
      end
    end
  rescue
    e ->
      require Logger
      Logger.warning("[PortRegistry] reconcile_proxies failed: #{Exception.message(e)}")
  end

  defp stop_all_proxies do
    for {key, _} <- :ets.tab2list(@table) do
      stop_proxy(key)
    end
  end

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
