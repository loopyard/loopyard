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
  @topic "docker_observer"
  @debounce_ms 500
  @retry_interval 5_000

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

  @doc "All `bl-*` volumes. Returns `[%{name, workspace_id}, ...]`."
  def volumes do
    case :ets.lookup(@table, :volumes) do
      [{_, list}] -> list
      _ -> []
    end
  end

  @doc "Volumes for one workspace."
  def volumes_for(workspace_id) do
    Enum.filter(volumes(), &(&1.workspace_id == workspace_id))
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

  @doc "Subscribe to state-change broadcasts."
  def subscribe do
    Phoenix.PubSub.subscribe(BoomLooper.PubSub, @topic)
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
    {:ok, %{table: @table, port: nil, debounce_ref: nil, prev: nil, line_buffer: ""},
     {:continue, :bootstrap}}
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

  # Event stream died
  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    Logger.warning("[Docker.Observer] Event stream exited (code #{code}). Wiping cache, retrying in #{@retry_interval}ms.")

    # Wipe cache — state is now untrustworthy
    :ets.insert(@table, {:containers, []})
    :ets.insert(@table, {:volumes, []})
    :ets.insert(@table, {:connected, false})

    broadcast({:docker_state_reset})

    # Retry after a delay
    Process.send_after(self(), :retry_bootstrap, @retry_interval)
    {:noreply, %{state | port: nil, prev: nil, line_buffer: ""}}
  end

  # Retry bootstrap after stream death
  def handle_info(:retry_bootstrap, state) do
    {:noreply, bootstrap(state)}
  end

  # Debounce timer fired → do the actual re-snapshot
  def handle_info(:debounced_poll, state) do
    {:noreply, do_snapshot(%{state | debounce_ref: nil})}
  end

  # Catch-all for unknown messages (PubSub, etc.)
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_cast(:poll_now, state) do
    # Cancel any pending debounce and snapshot immediately
    if state.debounce_ref, do: Process.cancel_timer(state.debounce_ref)
    {:noreply, do_snapshot(%{state | debounce_ref: nil})}
  end

  # ── Bootstrap: start stream FIRST, then snapshot ──

  defp bootstrap(state) do
    # Step 1: start the event stream so it begins buffering
    state = start_event_stream(state)

    # Step 2: snapshot while the stream buffers any concurrent changes
    state = do_snapshot(state)

    Logger.info("[Docker.Observer] Bootstrapped: #{length(containers())} containers, #{length(volumes())} volumes")

    state
  end

  defp start_event_stream(state) do
    case BoomLooper.Docker.open_port([
           "events",
           "--filter", "type=container",
           "--filter", "type=volume",
           "--format", "{{json .}}"
         ]) do
      {:error, reason} ->
        Logger.error("[Docker.Observer] #{reason}")
        :ets.insert(@table, {:connected, false})
        Process.send_after(self(), :retry_bootstrap, @retry_interval)
        state

      port when is_port(port) ->
        :ets.insert(@table, {:connected, true})
        %{state | port: port, line_buffer: ""}
    end
  end

  # ── Snapshot: one docker ps + one docker volume ls ──

  defp do_snapshot(state) do
    containers = fetch_containers()
    volumes = fetch_volumes()
    now = DateTime.utc_now()

    :ets.insert(@table, {:containers, containers})
    :ets.insert(@table, {:volumes, volumes})
    :ets.insert(@table, {:last_snapshot_at, now})

    snapshot = %{containers: containers, volumes: volumes}

    if snapshot != state.prev do
      broadcast({:docker_state_changed, snapshot})
    end

    %{state | prev: snapshot}
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
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&parse_container_line/1)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp parse_container_line(line) do
    case String.split(line, "\t", parts: 3) do
      [name, status, ports_str] ->
        running = String.starts_with?(status, "Up")
        workspace_id = extract_workspace_id(name)
        host_ports = parse_host_ports(ports_str)

        %{
          name: name,
          status: status,
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
        output
        |> String.split("\n", trim: true)
        |> Enum.map(fn name ->
          # Enrich with parsed purpose (type, service, description)
          # using VolumeManager's pure name parser — no docker calls.
          summary = BoomLooper.VolumeManager.volume_summary(name)

          Map.merge(summary, %{
            workspace_id: extract_workspace_id(name)
          })
        end)

      _ ->
        []
    end
  end

  # Extract workspace_id from container/volume names like "bl-dd73-dev-1" → "dd73"
  defp extract_workspace_id(name) do
    case Regex.run(~r/^bl-([a-f0-9]+)-/, name) do
      [_, ws_id] -> ws_id
      _ -> nil
    end
  end

  # Parse "0.0.0.0:33958->3000/tcp, ..." into %{3000 => 33958}
  defp parse_host_ports(ports_str) when is_binary(ports_str) do
    Regex.scan(~r/0\.0\.0\.0:(\d+)->(\d+)/, ports_str)
    |> Map.new(fn [_, host_port, container_port] ->
      {String.to_integer(container_port), String.to_integer(host_port)}
    end)
  end

  defp parse_host_ports(_), do: %{}

  # ── Debounce ──

  defp schedule_debounced_poll(%{debounce_ref: nil} = state) do
    ref = Process.send_after(self(), :debounced_poll, @debounce_ms)
    %{state | debounce_ref: ref}
  end

  # Already scheduled — don't stack timers
  defp schedule_debounced_poll(state), do: state

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

  defp broadcast(message) do
    Phoenix.PubSub.broadcast(BoomLooper.PubSub, @topic, message)
  end
end
