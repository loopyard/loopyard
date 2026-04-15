defmodule BoomLooper.PortRegistry do
  @moduledoc """
  Owns host-port allocation for every workspace.

  One global pool (default `4000..9999`, configurable). Workspaces
  request ports one at a time via `assign/3`. Assignments are sticky
  per `{workspace_id, service, container_port}` — the same call
  returns the same host port every time, and survives BEAM restarts
  via `BoomLooper.PortStore`. Destroying the workspace releases its
  entries back to the pool.

  No blocks, no contiguity guarantees, no project-level bookkeeping.
  In practice `docker compose up` serializes per-workspace assigns so
  ports come out contiguous anyway; if they don't one day, nothing
  downstream cares.

  ## Why a GenServer for writes

  Reads hit the `:port_registry` ETS table directly. Writes
  (`assign`, `release_workspace`, `seed`) go through this GenServer
  so the "lowest unused integer in range" scan can't race and
  double-assign a port to two concurrent callers. Write volume is
  low (one per compose up / down), so serializing is free.

  ## Exposure (v2)

  The `exposed: bool` field on each entry is persisted in v1 but not
  acted on. v2's `PortExposer` will toggle it and run a TCP proxy
  fronting the loopback-bound port.
  """

  use GenServer

  alias BoomLooper.{EventLog, PortStore}

  @table :port_registry

  # --- Public API ---

  @doc """
  Start the registry. Options:

    * `:port_range` — `Range.t` of host ports to allocate from. Defaults
      to `Application.get_env(:boom_looper, __MODULE__)[:port_range]`
      or `4000..9999`.
    * `:persist` — when `true` (default), writes go through `PortStore`
      to `~/.boomlooper/ports.json` and the registry restores from
      that file at startup. Tests pass `false` to stay in-memory.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Assign a host port for `{workspace_id, service, container_port}`.
  Returns `{:ok, host_port}` or `{:error, :port_pool_exhausted}`.
  Sticky: repeat calls with the same triple return the same port.
  """
  def assign(workspace_id, service, container_port)
      when is_binary(workspace_id) and is_binary(service) and is_integer(container_port) do
    GenServer.call(__MODULE__, {:assign, workspace_id, service, container_port})
  end

  @doc """
  Return the entry for `{workspace_id, service, container_port}` or
  `:none`. Reads directly from ETS — no GenServer round trip.
  """
  def get(workspace_id, service, container_port) do
    case :ets.lookup(@table, {workspace_id, service, container_port}) do
      [{_, entry}] -> {:ok, entry}
      [] -> :none
    end
  end

  @doc "List every entry for the given workspace. Direct ETS read."
  def list_for_workspace(workspace_id) do
    :ets.tab2list(@table)
    |> Enum.filter(fn {{ws, _, _}, _} -> ws == workspace_id end)
    |> Enum.map(fn {_, entry} -> entry end)
  end

  @doc """
  Release every entry for `workspace_id`. Returns `:ok` always —
  absent workspaces are a no-op, same as `Destructor.destroy/1`'s
  idempotent contract.
  """
  def release_workspace(workspace_id) when is_binary(workspace_id) do
    GenServer.call(__MODULE__, {:release_workspace, workspace_id})
  end

  @doc """
  Migration helper: insert a legacy entry with a pre-assigned host
  port. Marks `legacy: true` so audits can tell these apart from
  normal assigns. The host_port counts as in-use for future `assign`
  calls even if it's outside the configured range.
  """
  def seed(workspace_id, service, container_port, host_port)
      when is_binary(workspace_id) and is_binary(service) and
             is_integer(container_port) and is_integer(host_port) do
    GenServer.call(__MODULE__, {:seed, workspace_id, service, container_port, host_port})
  end

  @doc """
  Application supervisor callback: load persisted entries into ETS,
  or migrate from legacy `Compose.capture_port_map/1` if there's no
  `ports.json` yet.

  Must be called AFTER `ProjectRegistry.restore/0` so `list_workspaces`
  can enumerate known workspaces for the migration seed. The migration
  path runs exactly once; subsequent boots just read `ports.json`.
  """
  def restore do
    GenServer.call(__MODULE__, :restore)
  end

  @doc """
  Reconfigure the running registry (port range, persistence).
  Intended for tests that want a tight range or in-memory store
  without stopping and restarting the GenServer. Options accepted:
    * `:port_range` — new `Range.t`
    * `:persist` — `true` or `false`
  """
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

    state = %{
      port_range: port_range,
      persist: persist
    }

    # Persistence restore is NOT done here — it runs via explicit
    # restore/0 call from the application supervisor AFTER
    # ProjectRegistry.restore/0. The order matters because the
    # migration path needs known workspaces to seed legacy sticky
    # ports from Compose.capture_port_map/1.
    {:ok, state}
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
              exposed: false,
              legacy: false,
              allocated_at: DateTime.utc_now()
            }

            :ets.insert(@table, {key, entry})
            persist(state)
            EventLog.info("ports", "Assigned #{ws}/#{svc}/#{cport} → host #{host_port}")
            {:reply, {:ok, host_port}, state}

          {:error, :port_pool_exhausted} = err ->
            EventLog.error("ports", "Port pool exhausted while assigning #{ws}/#{svc}/#{cport}")
            {:reply, err, state}
        end
    end
  end

  def handle_call({:release_workspace, ws}, _from, state) do
    keys_to_delete =
      :ets.tab2list(@table)
      |> Enum.filter(fn {{w, _, _}, _} -> w == ws end)
      |> Enum.map(fn {key, _} -> key end)

    Enum.each(keys_to_delete, &:ets.delete(@table, &1))

    if keys_to_delete != [] do
      EventLog.info("ports", "Released #{length(keys_to_delete)} port(s) for workspace #{ws}")
      persist(state)
    end

    {:reply, :ok, state}
  end

  def handle_call({:seed, ws, svc, cport, host_port}, _from, state) do
    entry = %{
      workspace_id: ws,
      service: svc,
      container_port: cport,
      host_port: host_port,
      exposed: false,
      legacy: true,
      allocated_at: DateTime.utc_now()
    }

    :ets.insert(@table, {{ws, svc, cport}, entry})
    persist(state)
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
    cond do
      File.exists?(PortStore.path()) ->
        restore_entries()

      true ->
        # First boot after upgrade — seed from legacy sticky port maps.
        migrate_legacy()
        persist(state)
    end

    {:reply, :ok, state}
  end

  # --- Private ---

  defp find_free_port(range) do
    taken =
      :ets.tab2list(@table)
      |> MapSet.new(fn {_, entry} -> entry.host_port end)

    first_free =
      Enum.find(range, fn port -> not MapSet.member?(taken, port) end)

    if first_free, do: {:ok, first_free}, else: {:error, :port_pool_exhausted}
  end

  defp persist(%{persist: false}), do: :ok

  defp persist(%{persist: true, port_range: range}) do
    entries = :ets.tab2list(@table) |> Enum.map(fn {_, entry} -> entry end)
    PortStore.save(entries, range)
  end

  defp restore_entries do
    for entry <- PortStore.load() do
      key = {entry.workspace_id, entry.service, entry.container_port}
      :ets.insert(@table, {key, entry})
    end

    :ok
  end

  # Migration path — runs once on first boot after upgrade. Walks every
  # known workspace, asks `Compose.capture_port_map/1` for its existing
  # sticky host ports, and seeds them as `legacy: true` entries. Writes
  # a ports.json so subsequent boots take the fast path.
  defp migrate_legacy do
    try do
      workspaces =
        BoomLooper.ProjectRegistry.list_projects()
        |> Enum.flat_map(fn proj ->
          BoomLooper.WorkspaceRegistry.list_workspaces(proj.id)
        end)

      for ws <- workspaces do
        port_map =
          try do
            BoomLooper.Compose.capture_port_map(ws.id)
          rescue
            _ -> %{}
          end

        for {service, per_container} <- port_map,
            {container_port, host_port} <- per_container do
          entry = %{
            workspace_id: ws.id,
            service: to_string(service),
            container_port: to_i(container_port),
            host_port: to_i(host_port),
            exposed: false,
            legacy: true,
            allocated_at: DateTime.utc_now()
          }

          key = {entry.workspace_id, entry.service, entry.container_port}
          :ets.insert(@table, {key, entry})
        end
      end

      if :ets.info(@table, :size) > 0 do
        EventLog.info(
          "ports",
          "Seeded #{:ets.info(@table, :size)} legacy port entries from capture_port_map/1"
        )
      end

      :ok
    rescue
      e ->
        require Logger

        Logger.warning(
          "[PortRegistry] legacy migration skipped: #{Exception.message(e)}. " <>
            "New assigns will still work; old sticky ports may re-allocate."
        )

        :ok
    end
  end

  defp to_i(n) when is_integer(n), do: n
  defp to_i(n) when is_binary(n), do: String.to_integer(n)
end
