defmodule BoomLooper.Docker.Observer do
  @moduledoc """
  Event-driven Docker state cache.

  Maintains an ETS snapshot of all `bl-*` containers and volumes.
  LiveViews read from ETS directly (microseconds, zero docker calls).

  ## Bootstrap sequence

  1. Start `docker events` stream (buffering begins immediately)
  2. Run `docker ps -a` + `docker volume ls` to get the full truth
  3. Write snapshot to ETS, broadcast initial state
  4. Any events that arrived during step 2 are redundant — the snapshot
     already contains their effect. The next event that represents a
     REAL change triggers a debounced re-snapshot.

  Starting the event stream BEFORE the snapshot means there's zero gap
  where changes could be missed. Events during the snapshot window are
  harmless (re-snapshot catches them idempotently).

  ## Steady state

  Events arrive → debounced re-snapshot (500ms) → diff against previous
  → if changed, write ETS + broadcast PubSub. When nothing changes
  (steady state), zero shell-outs. When 5 containers start in rapid
  succession, one re-snapshot after the flurry settles.

  ## Failure recovery

  If the `docker events` port dies (daemon restart, Colima crash):
  1. Wipe ETS → broadcast `{:docker_state_reset}`
  2. Retry with backoff until Docker comes back
  3. Re-bootstrap (start stream → snapshot → seed ETS)

  ## Multi-node

  Each node runs its own Observer against its local Docker daemon.
  PubSub broadcasts route across nodes via distributed Erlang, so
  LiveViews on a remote node still see updates. The workspace-affinity
  model (one workspace per node) means each Observer only sees its
  own containers.
  """

  use GenServer
  require Logger

  @table :docker_observer
  @debounce_ms 500

  # Backstop reconciler: re-snapshot every interval even if no events
  # arrived. Covers the "event stream silently stopped emitting" case
  # (kernel bug, daemon stall, filter evaluator corner case). 30s is
  # a balance between freshness and shell-out frequency.
  @reconcile_interval_ms 30_000

  # Backoff schedule for event-stream reconnect. 1s → 60s cap. Resets
  # to the head of the list on successful bootstrap.
  @retry_backoff_ms [1_000, 2_000, 4_000, 8_000, 16_000, 30_000, 60_000]

  # After this many consecutive snapshot fetches fail, the cache is
  # considered stale enough that we clear it to avoid lying to the UI.
  # One or two failures are just transient daemon hiccups — keep the
  # last-known state through those.
  @stale_cache_threshold 6

  # ── Public API (all ETS reads, zero GenServer hops) ──

  @doc "All `bl-*` containers. Returns `[%{name, status, running, workspace_id}, ...]`."
  def containers do
    case :ets.lookup(@table, :containers) do
      [{_, list}] -> list
      _ -> []
    end
  end

  @doc "Containers for one workspace."
  def containers_for(workspace_id) do
    Enum.filter(containers(), &(&1.workspace_id == workspace_id))
  end

  @doc """
  All `bl-*` volumes. Returns `[%{name, workspace_id, size, ...}, ...]`.

  Merges the stable volume list with the separately-stored size map.
  Sizes update on every snapshot but don't contribute to the snapshot
  comparison that drives broadcasts — see `do_snapshot/1`.
  """
  def volumes do
    list =
      case :ets.lookup(@table, :volumes) do
        [{_, list}] -> list
        _ -> []
      end

    sizes =
      case :ets.lookup(@table, :volume_sizes) do
        [{_, sizes}] -> sizes
        _ -> %{}
      end

    Enum.map(list, fn v -> Map.put(v, :size, Map.get(sizes, v.name)) end)
  end

  @doc "Volumes for one workspace."
  def volumes_for(workspace_id) do
    Enum.filter(volumes(), &(&1.workspace_id == workspace_id))
  end

  @doc """
  Full service list for a workspace: defined services from the compose file
  merged with running state from the Observer's container cache.

  This is the ONLY function UI code should call for service data. It reads
  the compose file from workspace.compose_dir (via Workspace.compose_dir/1)
  and merges with cached container state — never shells out to Docker.

  Returns a list of `%ServiceStatus.Service{}` structs.
  """
  def services_for(workspace_id) do
    compose_dir = BoomLooper.Workspace.compose_dir(workspace_id)
    project_name = BoomLooper.Compose.project_name(workspace_id)
    observer_containers = containers_for(workspace_id)

    defined = BoomLooper.Workspace.ServiceStatus.list_defined_services(compose_dir)

    if defined != [] do
      Enum.map(defined, fn svc ->
        container_name = "#{project_name}-#{svc.name}-1"
        container = Enum.find(observer_containers, &(&1.name == container_name))

        if container && container.running do
          struct!(svc, %{
            status: :running,
            container: container_name,
            ports: container[:host_ports] || %{}
          })
        else
          struct!(svc, %{status: :stopped, container: container_name})
        end
      end)
    else
      # No compose file — derive from running containers
      observer_containers
      |> Enum.reject(&String.ends_with?(&1.name, "-workspace-1"))
      |> Enum.map(fn c ->
        service_name =
          c.name
          |> String.replace_prefix("#{project_name}-", "")
          |> String.replace_suffix("-1", "")

        %BoomLooper.Workspace.ServiceStatus.Service{
          name: service_name,
          type: :process,
          status: if(c.running, do: :running, else: :stopped),
          container: c.name,
          ports: c[:host_ports] || %{}
        }
      end)
    end
  end

  @doc "Full snapshot: containers + volumes + timestamp."
  def snapshot do
    %{
      containers: containers(),
      volumes: volumes(),
      last_snapshot_at: last_snapshot_at()
    }
  end

  @doc "When did the last snapshot complete?"
  def last_snapshot_at do
    case :ets.lookup(@table, :last_snapshot_at) do
      [{_, dt}] -> dt
      _ -> nil
    end
  end

  @doc "Is the event stream connected to Docker?"
  def connected? do
    case :ets.lookup(@table, :connected) do
      [{_, true}] -> true
      _ -> false
    end
  end

  @doc """
  Observer health snapshot. Use for UI diagnostics and tests.

  Fields:
    * `:connected` — is the event stream attached?
    * `:last_snapshot_at` — when did a fetch last successfully update the cache?
    * `:snapshot_failures` — consecutive fetch failures since last success
      (non-zero means the cache is running on last-known state; ≥
      `@stale_cache_threshold` means it's been wiped)
    * `:reconciles` — count of successful periodic reconciler runs (lets
      tests verify the backstop timer is actually firing)
  """
  def health do
    # Pure ETS reads — no GenServer.call, no blocking. Keeps callers
    # (health dashboards, tests, rpc debug) fast even while the
    # Observer is mid-snapshot and not answering calls.
    %{
      connected: connected?(),
      last_snapshot_at: last_snapshot_at(),
      snapshot_failures: read_counter(:snapshot_failures),
      reconciles: read_counter(:reconciles)
    }
  end

  defp read_counter(key) do
    case :ets.lookup(@table, key) do
      [{^key, n}] when is_integer(n) -> n
      _ -> 0
    end
  end

  @doc "Subscribe to state-change broadcasts."
  def subscribe do
    BoomLooper.Events.DockerObserver.subscribe()
  end

  @doc """
  Force an immediate re-snapshot. Use after mutating Docker state
  (e.g. after `docker_compose up -d`) so LiveViews see the change
  within milliseconds instead of waiting for the next event.
  """
  def poll_now do
    GenServer.cast(__MODULE__, :poll_now)
  end

  # ── GenServer ──

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    # ETS table is pre-created by BoomLooper.StateKeeper.
    state = %{
      table: @table,
      port: nil,
      debounce_ref: nil,
      reconcile_ref: nil,
      prev: nil,
      line_buffer: "",
      retry_attempt: 0,
      snapshot_failures: 0,
      reconciles: 0
    }

    {:ok, state, {:continue, :bootstrap}}
  end

  @impl true
  def handle_continue(:bootstrap, state) do
    {:noreply, bootstrap(state)}
  end

  # ── Event stream data ──

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    # docker events streams JSON lines. Data may arrive in chunks
    # (partial lines) or multiple lines at once. Buffer and split.
    buffer = state.line_buffer <> data
    {lines, remainder} = split_lines(buffer)

    # Any line = something changed. We don't parse the event content;
    # we just use it as an invalidation trigger for a full re-snapshot.
    state = %{state | line_buffer: remainder}

    state =
      if lines != [] do
        schedule_debounced_poll(state)
      else
        state
      end

    {:noreply, state}
  end

  # Event stream died — the daemon went away or the port itself
  # crashed. Keep the last-known cache visible (marked stale via
  # :connected=false) and retry with exponential backoff. Blanking the
  # UI on a 2-second Colima blip caused more confusion than a "last
  # seen N seconds ago" badge, so the cache stays until either we
  # reconnect (overwriting it) or @stale_cache_threshold consecutive
  # snapshot failures wipe it below.
  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    delay = backoff_delay(state.retry_attempt)

    Logger.warning(
      "[Docker.Observer] Event stream exited (code #{code}); " <>
        "retry ##{state.retry_attempt + 1} in #{delay}ms. " <>
        "Cache retained pending reconnect."
    )

    :ets.insert(@table, {:connected, false})
    BoomLooper.Events.DockerObserver.publish(%BoomLooper.Events.DockerObserver.Disconnected{})

    Process.send_after(self(), :retry_bootstrap, delay)

    state =
      state
      |> cancel_reconcile()
      |> Map.merge(%{port: nil, line_buffer: "", retry_attempt: state.retry_attempt + 1})

    {:noreply, state}
  end

  # Retry bootstrap after stream death
  def handle_info(:retry_bootstrap, state) do
    {:noreply, bootstrap(state)}
  end

  # Debounce timer fired → do the actual re-snapshot
  def handle_info(:debounced_poll, state) do
    {:noreply, do_snapshot(%{state | debounce_ref: nil})}
  end

  # Periodic reconciler — independent of event stream so we catch the
  # "events are silently not firing" class of bug. Always reschedules
  # itself (even on snapshot failure) so the backstop keeps ticking.
  def handle_info(:reconcile, state) do
    reconciles = state.reconciles + 1
    :ets.insert(@table, {:reconciles, reconciles})
    state = do_snapshot(%{state | reconcile_ref: nil, reconciles: reconciles})
    {:noreply, schedule_reconcile(state)}
  end

  def handle_info(msg, state) do
    Logger.warning("[Docker.Observer] unhandled: #{inspect(msg, limit: 200)}")

    :telemetry.execute(
      [:boom_looper, :actor, :unknown_message],
      %{count: 1},
      %{actor: __MODULE__, msg: inspect(msg, limit: 200)}
    )

    {:noreply, state}
  end

  @impl true
  def handle_cast(:poll_now, state) do
    # Cancel any pending debounce and snapshot immediately
    if state.debounce_ref, do: Process.cancel_timer(state.debounce_ref)
    {:noreply, do_snapshot(%{state | debounce_ref: nil})}
  end

  # Note: no handle_call(:health) — health/0 reads purely from ETS
  # to stay fast and non-blocking even while the Observer is busy.

  # ── Bootstrap: start stream FIRST, then snapshot ──

  defp bootstrap(state) do
    # Step 1: start the event stream so it begins buffering. If this
    # fails (daemon unreachable), start_event_stream schedules the
    # next retry and returns state unchanged — we DON'T snapshot
    # because there's nothing to snapshot.
    case start_event_stream(state) do
      {:ok, state} ->
        # Step 2: snapshot while the stream buffers any concurrent
        # changes. A snapshot failure here keeps the last-known cache.
        state = do_snapshot(state)

        Logger.info(
          "[Docker.Observer] Bootstrapped: #{length(containers())} containers, " <>
            "#{length(volumes())} volumes"
        )

        # Start the backstop reconciler. Cheap if the event stream
        # stays healthy; the safety net if it doesn't.
        state = schedule_reconcile(state)

        # Reconnected successfully — reset backoff, notify subscribers
        # that cache is trustworthy again.
        BoomLooper.Events.DockerObserver.publish(%BoomLooper.Events.DockerObserver.Reconnected{})
        %{state | retry_attempt: 0}

      {:retry_scheduled, state} ->
        state
    end
  end

  defp start_event_stream(state) do
    case BoomLooper.Docker.open_port([
           "events",
           "--filter", "type=container",
           "--filter", "type=volume",
           "--format", "{{json .}}"
         ]) do
      {:error, reason} ->
        delay = backoff_delay(state.retry_attempt)
        Logger.error("[Docker.Observer] #{reason}; retry in #{delay}ms")
        :ets.insert(@table, {:connected, false})
        Process.send_after(self(), :retry_bootstrap, delay)
        {:retry_scheduled, %{state | retry_attempt: state.retry_attempt + 1}}

      port when is_port(port) ->
        :ets.insert(@table, {:connected, true})
        {:ok, %{state | port: port, line_buffer: ""}}
    end
  end

  # ── Snapshot: one docker ps + one docker volume ls ──
  #
  # Fail-safe semantics: if either the containers or volumes fetch
  # returns an error (CLI timeout, daemon blip), we KEEP the previous
  # cache and bump snapshot_failures. Only after the counter passes
  # @stale_cache_threshold do we wipe the cache and signal a reset —
  # at that point the data is old enough that showing stale state
  # would mislead more than blanking it.
  #
  # Past bug: a single `docker ps` timeout returned [] which got
  # written to ETS, broadcasting {:docker_state_changed} and flashing
  # every sidebar empty for the 500ms until the next snapshot filled
  # it back in.

  defp do_snapshot(state) do
    case {fetch_containers(), fetch_volumes()} do
      {{:ok, containers}, {:ok, volumes}} ->
        commit_snapshot(state, containers, volumes)

      {c_result, v_result} ->
        handle_snapshot_failure(state, c_result, v_result)
    end
  end

  defp commit_snapshot(state, containers, volumes) do
    # Volume sizes are pulled separately — they're a nice-to-have and
    # a failure here only drops size rendering, never container truth.
    volume_sizes = fetch_volume_sizes() |> case do
      {:ok, sizes} -> sizes
      :error -> %{}
    end

    now = DateTime.utc_now()

    :ets.insert(@table, {:containers, containers})
    :ets.insert(@table, {:volumes, volumes})
    :ets.insert(@table, {:volume_sizes, volume_sizes})
    :ets.insert(@table, {:last_snapshot_at, now})

    # `snapshot` carries only identity + functional state. Volatile
    # metrics (container uptime strings, volume byte sizes) live in
    # separate ETS slots and are NOT part of this comparison — otherwise
    # every tick of uptime or every byte written to a volume would
    # broadcast and flash the sidebar.
    snapshot = %{containers: containers, volumes: volumes}

    if snapshot != state.prev do
      # Notification-only. Subscribers re-read from the ETS cache
      # (Observer.containers/0, .volumes/0, .services_for/1). Shipping
      # the snapshot in the broadcast let consumers bypass the cache
      # API and drift from what the UI actually needs — one such drift
      # caused the sidebar-port flash.
      BoomLooper.Events.DockerObserver.publish(%BoomLooper.Events.DockerObserver.Changed{})
    end

    # Mirror the success-reset into ETS so health() reads it without
    # a GenServer round-trip. Same for snapshot_failures below.
    :ets.insert(@table, {:snapshot_failures, 0})

    %{state | prev: snapshot, snapshot_failures: 0}
  end

  defp handle_snapshot_failure(state, c_result, v_result) do
    failures = state.snapshot_failures + 1
    :ets.insert(@table, {:snapshot_failures, failures})

    Logger.warning(
      "[Docker.Observer] Snapshot failed (consecutive=#{failures}); " <>
        "containers=#{inspect(c_result)} volumes=#{inspect(v_result)}"
    )

    cond do
      failures >= @stale_cache_threshold ->
        Logger.error(
          "[Docker.Observer] Stale-cache threshold hit (#{@stale_cache_threshold} " <>
            "consecutive failures); wiping cache."
        )

        :ets.insert(@table, {:containers, []})
        :ets.insert(@table, {:volumes, []})
        :ets.insert(@table, {:volume_sizes, %{}})
        BoomLooper.Events.DockerObserver.publish(%BoomLooper.Events.DockerObserver.Reset{})

        %{state | prev: %{containers: [], volumes: []}, snapshot_failures: failures}

      true ->
        # Keep last-known cache. UI reflects :connected=false (set on
        # port exit) so viewers know they're looking at potentially
        # stale data.
        %{state | snapshot_failures: failures}
    end
  end

  defp fetch_containers do
    case BoomLooper.Docker.docker(
           [
             "ps", "-a",
             "--filter", "name=bl-",
             "--format", "{{.Names}}\t{{.Status}}\t{{.Ports}}"
           ],
           env: [{"LC_ALL", "C"}]
         ) do
      {:ok, output} ->
        parsed =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(&parse_container_line/1)
          |> Enum.reject(&is_nil/1)

        {:ok, parsed}

      _ ->
        :error
    end
  end

  defp parse_container_line(line) do
    case String.split(line, "\t", parts: 3) do
      [name, status, ports_str] ->
        # `status` is Docker's raw "Up 5 seconds" / "Exited (0) 3 minutes
        # ago" string. The uptime portion ticks every second and used to
        # make every snapshot compare unequal, triggering a broadcast
        # and a sidebar re-render on every tick. Keep only the identity +
        # functional state; UI derives what it needs from `running`.
        running = String.starts_with?(status, "Up")
        workspace_id = extract_workspace_id(name)
        host_ports = parse_host_ports(ports_str)

        %{
          name: name,
          running: running,
          workspace_id: workspace_id,
          host_ports: host_ports
        }

      _ ->
        nil
    end
  end

  defp fetch_volumes do
    case BoomLooper.Docker.docker([
           "volume", "ls",
           "--filter", "name=bl-",
           "--format", "{{.Name}}"
         ]) do
      {:ok, output} ->
        # Volume sizes used to be attached here, but they grow over time
        # (as files are written) and flipped the snapshot != prev check
        # every snapshot — broadcasting constant docker_state_changed
        # events that flashed the sidebar. Sizes are now a separate
        # concern: see :volume_sizes ETS slot and `volume_size/1`. The
        # snapshot comparison stays stable when only sizes change.
        parsed =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(fn name ->
            # Enrich with parsed purpose (type, service, description)
            # using VolumeManager's pure name parser — no docker calls.
            summary = BoomLooper.VolumeManager.volume_summary(name)

            Map.merge(summary, %{workspace_id: extract_workspace_id(name)})
          end)

        {:ok, parsed}

      _ ->
        :error
    end
  end

  # Returns `%{volume_name => size_string}` for every local volume. Uses
  # `docker system df -v` which reports all volume sizes in one call.
  # The `--format '{{json .}}'` variant emits a JSON object with a
  # `Volumes` array whose entries have `Name` and `Size` (pre-formatted
  # like "145.3MB"). Returns `{:ok, map}` or `:error` — callers tolerate
  # size failures without blanking volume identity.
  defp fetch_volume_sizes do
    case BoomLooper.Docker.docker(["system", "df", "-v", "--format", "{{json .}}"],
           timeout: 5_000,
           retry: false
         ) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, %{"Volumes" => volumes}} when is_list(volumes) ->
            sizes =
              for %{"Name" => name, "Size" => size} <- volumes,
                  is_binary(name) and is_binary(size),
                  into: %{},
                  do: {name, size}

            {:ok, sizes}

          _ ->
            :error
        end

      _ ->
        :error
    end
  end

  # Extract workspace_id from container/volume names like "bl-dd73-dev-1" → "dd73"
  defp extract_workspace_id(name) do
    case Regex.run(~r/^bl-([a-f0-9]+)-/, name) do
      [_, ws_id] -> ws_id
      _ -> nil
    end
  end

  # Parse "127.0.0.1:33958->3000/tcp, ..." (or 0.0.0.0:... / [::]:...)
  # into %{3000 => 33958}. We bind published ports to 127.0.0.1 for
  # per-workspace network isolation (see docs/SECURITY.md § Network
  # isolation), so the IP portion of `docker ps --format {{.Ports}}`
  # is no longer 0.0.0.0. Match any IPv4 literal or IPv6 `[::]` prefix
  # so the sidebar link survives changes to the host bind address.
  @doc false
  def parse_host_ports(ports_str) when is_binary(ports_str) do
    Regex.scan(~r/(?:\[::\]|(?:\d{1,3}\.){3}\d{1,3}):(\d+)->(\d+)/, ports_str)
    |> Map.new(fn [_, host_port, container_port] ->
      {String.to_integer(container_port), String.to_integer(host_port)}
    end)
  end

  def parse_host_ports(_), do: %{}

  # ── Debounce ──

  defp schedule_debounced_poll(%{debounce_ref: nil} = state) do
    ref = Process.send_after(self(), :debounced_poll, @debounce_ms)
    %{state | debounce_ref: ref}
  end

  # Already scheduled — don't stack timers
  defp schedule_debounced_poll(state), do: state

  # ── Reconciler ──

  defp schedule_reconcile(state) do
    state = cancel_reconcile(state)
    ref = Process.send_after(self(), :reconcile, @reconcile_interval_ms)
    %{state | reconcile_ref: ref}
  end

  defp cancel_reconcile(%{reconcile_ref: nil} = state), do: state

  defp cancel_reconcile(%{reconcile_ref: ref} = state) do
    Process.cancel_timer(ref)
    %{state | reconcile_ref: nil}
  end

  # ── Backoff ──
  #
  # Walk the backoff list; stick on the final (largest) interval if
  # we've been trying for longer than the table covers. Resetting
  # retry_attempt to 0 on a successful bootstrap walks this back to
  # the head of the list.
  @doc false
  def backoff_delay(attempt) do
    Enum.at(@retry_backoff_ms, attempt, List.last(@retry_backoff_ms))
  end

  @doc false
  def stale_cache_threshold, do: @stale_cache_threshold

  # ── Helpers ──

  defp split_lines(buffer) do
    parts = String.split(buffer, "\n")

    case parts do
      [] -> {[], ""}
      [single] -> {[], single}  # no newline yet, keep buffering
      _ ->
        {complete, [remainder]} = Enum.split(parts, -1)
        {Enum.reject(complete, &(&1 == "")), remainder}
    end
  end

  # All broadcasts go through BoomLooper.Events.DockerObserver —
  # the CI boundary test forbids Phoenix.PubSub.broadcast elsewhere.
end
