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
  Release a single entry by `{workspace_id, service, container_port}`.
  Used by the Resources janitor when the owning workspace supervisor
  goes DOWN, and internally by `release_workspace/1`. Returns `:ok`
  whether or not the entry existed.
  """
  def release_entry(workspace_id, service, container_port)
      when is_binary(workspace_id) and is_binary(service) and is_integer(container_port) do
    GenServer.call(__MODULE__, {:release_entry, workspace_id, service, container_port})
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
  Open (`true`) or close (`false`) public exposure for a registered
  port. Toggling the field and starting/stopping the `PortExposer`
  GenServer are done atomically inside the registry's GenServer so
  the flag and the listener can never drift.

  Returns `:ok` on success; `{:error, :not_registered}` if the key
  doesn't exist; `{:error, reason}` if the listener can't bind.
  """
  def set_exposure(workspace_id, service, container_port, exposed?)
      when is_binary(workspace_id) and is_binary(service) and
             is_integer(container_port) and is_boolean(exposed?) do
    GenServer.call(
      __MODULE__,
      {:set_exposure, workspace_id, service, container_port, exposed?}
    )
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
  Retry exposing a single entry. Operator / UI path for recovering
  an entry that landed in `exposure_error` state (agent-sanity #7).

  Runs the same auto-reassign logic `restore_entries` uses on boot:
  tries the currently-recorded host_port; on EADDRINUSE, allocates a
  fresh free port, persists the reassignment, retries. Returns
  `:ok` on success or `{:error, reason}`.
  """
  def retry_exposure(workspace_id, service, container_port) do
    GenServer.call(
      __MODULE__,
      {:retry_exposure, workspace_id, service, container_port}
    )
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
      persist: persist,
      reserved: reserved_ports()
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
            track_port_binding(ws, svc, cport)
            {:reply, {:ok, host_port}, state}

          {:error, :port_pool_exhausted} = err ->
            EventLog.error("ports", "Port pool exhausted while assigning #{ws}/#{svc}/#{cport}")
            {:reply, err, state}
        end
    end
  end

  def handle_call({:release_workspace, ws}, _from, state) do
    entries =
      :ets.tab2list(@table)
      |> Enum.filter(fn {{w, _, _}, _} -> w == ws end)

    for {key, entry} <- entries do
      # Stop any running exposer so we don't leak a listener on the
      # host port after the workspace is gone.
      if entry.exposed do
        toggle_exposer(key, entry, false)
      end

      :ets.delete(@table, key)
      # Untrack explicitly — prevents the Resources janitor from
      # double-releasing if the workspace supervisor dies later.
      BoomLooper.Resources.release(:port_binding, key)
    end

    if entries != [] do
      EventLog.info("ports", "Released #{length(entries)} port(s) for workspace #{ws}")
      persist(state)
    end

    {:reply, :ok, state}
  end

  def handle_call({:release_entry, ws, svc, cport}, _from, state) do
    key = {ws, svc, cport}

    case :ets.lookup(@table, key) do
      [{^key, entry}] ->
        if entry.exposed do
          toggle_exposer(key, entry, false)
        end

        :ets.delete(@table, key)
        persist(state)
        EventLog.info("ports", "Released #{ws}/#{svc}/#{cport}")
        # Untrack from Resources too — idempotent, and handles the
        # case where release_entry is called outside of the janitor
        # DOWN path (future callers; today only the janitor task
        # calls it, but don't leak tracking state if that changes).
        BoomLooper.Resources.release(:port_binding, key)

      [] ->
        :ok
    end

    {:reply, :ok, state}
  end

  def handle_call({:set_exposure, ws, svc, cport, exposed?}, _from, state) do
    key = {ws, svc, cport}

    case :ets.lookup(@table, key) do
      [] ->
        {:reply, {:error, :not_registered}, state}

      [{^key, entry}] when entry.exposed == exposed? ->
        # No-op: already in the desired state. Don't churn the
        # listener or spam EventLog.
        {:reply, :ok, state}

      [{^key, entry}] ->
        case toggle_exposer(key, entry, exposed?) do
          :ok ->
            updated = %{entry | exposed: exposed?}
            :ets.insert(@table, {key, updated})
            persist(state)
            {:reply, :ok, state}

          {:error, reason} = err ->
            EventLog.error(
              "ports",
              "Failed to #{if exposed?, do: "open", else: "close"} exposure " <>
                "for #{ws}/#{svc}/#{cport}: #{inspect(reason)}"
            )

            {:reply, err, state}
        end
    end
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

  def handle_call({:retry_exposure, ws, svc, cport}, _from, state) do
    key = {ws, svc, cport}

    case :ets.lookup(@table, key) do
      [{^key, entry}] ->
        # Clear any prior error marker before the retry so a repeat
        # success cleanly resets the state.
        cleaned = entry |> Map.delete(:exposure_error) |> Map.delete(:exposure_error_at)
        :ets.insert(@table, {key, cleaned})

        result = start_exposer_with_reassign(key, cleaned, state.port_range)
        {:reply, result, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
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

  # Register the port binding under the workspace supervisor pid so
  # the Resources.Janitor releases it automatically when the group
  # dies for any reason (normal shutdown, crash, :kill). If the
  # workspace supervisor isn't up yet — e.g. seed / migration path
  # runs before the group exists — we skip tracking. The next
  # explicit `release_workspace/1` still works via direct ETS
  # cleanup. Plan: Move #7b.
  defp track_port_binding(ws, svc, cport) do
    key = {ws, svc, cport}

    case BoomLooper.WorkspaceGroup.whereis(ws) do
      nil ->
        :ok

      pid when is_pid(pid) ->
        BoomLooper.Resources.track(
          pid,
          :port_binding,
          key,
          fn ->
            # The release runs inside the Janitor GenServer. We can't
            # synchronously GenServer.call back into PortRegistry from
            # here — if PortRegistry is in the middle of its own
            # Resources.track call, we'd deadlock both processes. Run
            # the release in a supervised Task so the Janitor's loop
            # unblocks immediately.
            Task.Supervisor.start_child(BoomLooper.TaskSupervisor, fn ->
              BoomLooper.PortRegistry.release_entry(ws, svc, cport)
            end)

            :ok
          end
        )

        :ok
    end
  end

  # Ports the registry must NEVER hand out: anything BoomLooper itself
  # binds (Phoenix endpoint, SSH server) or similar host services. Without
  # this, compose port 4000 would get assigned over Phoenix's own :4000,
  # displacing the dev UI with a workspace container.
  defp reserved_ports do
    endpoint_port =
      case Application.get_env(:boom_looper, BoomLooperWeb.Endpoint) do
        nil -> nil
        cfg -> get_in(cfg, [:http, :port])
      end

    [endpoint_port]
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp find_free_port(range) do
    find_free_port(range, reserved_ports())
  end

  defp find_free_port(range, reserved) do
    taken =
      :ets.tab2list(@table)
      |> MapSet.new(fn {_, entry} -> entry.host_port end)
      |> MapSet.union(reserved)

    # Walk the range, skip registry-taken + reserved, then trial-bind
    # each candidate to confirm no OTHER process (docker proxy, node,
    # whatever) is already holding it. Without this we'd hand out an
    # occupied port and the container would fail to start with
    # EADDRINUSE — or worse, hijack a port we didn't know about.
    first_free =
      Enum.find(range, fn port ->
        not MapSet.member?(taken, port) and port_os_free?(port)
      end)

    if first_free, do: {:ok, first_free}, else: {:error, :port_pool_exhausted}
  end

  # Trial-listen on 0.0.0.0:<port>. Success = nobody has it. We bind to
  # 0.0.0.0 on purpose — a port held on 127.0.0.1 would still fail the
  # 0.0.0.0 bind, and a port held on 0.0.0.0 blocks loopback too. Either
  # way, if this bind succeeds the port is genuinely free for our use.
  defp port_os_free?(port) do
    case :gen_tcp.listen(port, [:binary, ip: {0, 0, 0, 0}, active: false]) do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        true

      {:error, _} ->
        false
    end
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

      # Re-open exposure for entries that were exposed at shutdown.
      # On the happy path, start_exposer binds the same host_port we
      # had before. If that host_port is no longer available
      # (docker-proxy leak from a killed container, TIME_WAIT, another
      # process grabbed it), fall back to reassigning a fresh port +
      # persisting the update. Agent-sanity #7.
      if entry.exposed do
        start_exposer_with_reassign(key, entry, default_port_range())
      end
    end

    :ok
  end

  # Re-open exposure with auto-reassign on EADDRINUSE.
  #
  # 1. Try the originally-persisted host_port (preserves URLs across
  #    restarts on the common path).
  # 2. If it fails with :eaddrinuse / :listen_failed, allocate a fresh
  #    free port, update the entry, persist, and retry.
  # 3. If still failing, mark the entry with an `exposure_error` so
  #    /system/* can render the degraded state.
  #
  # Telemetry fires for both successful reassignments and ultimate
  # failures — ops needs to see port pressure trends.
  defp start_exposer_with_reassign(key, entry, port_range) do
    case start_exposer(key, entry) do
      :ok ->
        :ok

      {:error, {:listen_failed, :eaddrinuse}} ->
        reassign_and_retry(key, entry, port_range, :eaddrinuse)

      {:error, {:listen_failed, reason}} ->
        reassign_and_retry(key, entry, port_range, reason)

      {:error, reason} ->
        mark_exposure_failed(key, entry, reason)

        require Logger

        Logger.warning(
          "[PortRegistry] Could not re-open exposure for #{inspect(key)}: " <>
            "#{inspect(reason)}. Entry marked exposure_error; retry via UI or release_entry/3."
        )

        {:error, reason}
    end
  end

  defp reassign_and_retry(key, entry, port_range, original_reason) do
    case find_free_port(port_range) do
      {:ok, new_host_port} ->
        :telemetry.execute(
          [:boom_looper, :port_registry, :reassigned],
          %{count: 1},
          %{
            workspace_id: elem(key, 0),
            service: elem(key, 1),
            container_port: elem(key, 2),
            old_host_port: entry.host_port,
            new_host_port: new_host_port,
            reason: original_reason
          }
        )

        new_entry = %{entry | host_port: new_host_port}
        :ets.insert(@table, {key, new_entry})
        # Persist immediately so the next restart uses the new port
        # instead of re-hitting the same conflict.
        PortStore.save(
          :ets.tab2list(@table) |> Enum.map(fn {_, e} -> e end),
          port_range
        )

        require Logger

        Logger.info(
          "[PortRegistry] Reassigned #{inspect(key)} from host :#{entry.host_port} " <>
            "to :#{new_host_port} (#{original_reason}). Re-attempting exposure."
        )

        case start_exposer(key, new_entry) do
          :ok ->
            :ok

          {:error, reason2} ->
            mark_exposure_failed(key, new_entry, reason2)

            Logger.warning(
              "[PortRegistry] Reassign succeeded but exposure still failed for " <>
                "#{inspect(key)} at :#{new_host_port}: #{inspect(reason2)}"
            )

            {:error, reason2}
        end

      {:error, :port_pool_exhausted} ->
        mark_exposure_failed(key, entry, {:port_pool_exhausted, original_reason})

        require Logger

        Logger.error(
          "[PortRegistry] Could not reassign for #{inspect(key)}: port pool exhausted."
        )

        {:error, :port_pool_exhausted}
    end
  end

  defp mark_exposure_failed(key, entry, reason) do
    marked =
      Map.merge(entry, %{
        exposure_error: reason,
        exposure_error_at: DateTime.utc_now()
      })

    :ets.insert(@table, {key, marked})

    :telemetry.execute(
      [:boom_looper, :port_registry, :reopen_failed],
      %{count: 1},
      %{
        workspace_id: elem(key, 0),
        service: elem(key, 1),
        container_port: elem(key, 2),
        host_port: entry.host_port,
        reason: reason
      }
    )
  end

  defp default_port_range do
    Application.get_env(:boom_looper, __MODULE__)[:port_range] || 4000..9999
  end

  # Start or stop the PortExposer for a given key, depending on the
  # target state. Returns :ok on success or {:error, reason}.
  defp toggle_exposer(key, entry, true) do
    case BoomLooper.PortExposer.whereis(key) do
      nil -> start_exposer(key, entry)
      _pid -> :ok
    end
  end

  defp toggle_exposer(key, _entry, false) do
    case BoomLooper.PortExposer.whereis(key) do
      nil ->
        :ok

      pid ->
        DynamicSupervisor.terminate_child(BoomLooper.PortExposerSupervisor, pid)
        :ok
    end
  end

  defp start_exposer(key, entry) do
    spec = {BoomLooper.PortExposer, key: key, host_port: entry.host_port}

    case DynamicSupervisor.start_child(BoomLooper.PortExposerSupervisor, spec) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, reason} -> {:error, reason}
    end
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
