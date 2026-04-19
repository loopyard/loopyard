defmodule BoomLooper.Resources.Janitor do
  @moduledoc """
  Supervised GenServer backing `BoomLooper.Resources`. Owns the
  `:resource_registry` ETS table and monitors every owner pid.

  Move #7b in `plans/coordination-hardening.md`.

  ## ETS layout

  One row per tracked resource, keyed by `{kind, id}`:

      {{:port_binding, {"ws-abc", "web", 3000}}, owner_pid, release_fn, inserted_at_us}

  A second shape-erased lookup index (`owner_pid → [{kind, id}]`)
  is kept in a plain `Map` in GenServer state. Owner-scan on DOWN
  walks that map instead of the full ETS table — keeps the DOWN
  handler O(resources-per-owner), not O(total-resources).

  ## DOWN handling

  On `{:DOWN, _ref, :process, pid, reason}`, the janitor:

    1. Looks up every `{kind, id}` owned by `pid`.
    2. For each, runs `release_fn` inside a `try/rescue` so a
       crashing release doesn't take down the janitor and doesn't
       prevent other resources from releasing.
    3. Deletes the ETS rows and removes the pid from the index.
    4. Fires `[:boom_looper, :resources, :released]` telemetry per
       release.

  The janitor never crashes as a result of a release callback — the
  invariant is "owner dies → resources released, one way or
  another." A crashing release is a bug in the caller, not a reason
  to lose the rest of the cleanup.

  ## Start order

  Must start AFTER `StateKeeper` (which creates the ETS table) and
  BEFORE any module that calls `Resources.track/4`. In practice
  that means it lives high in the supervisor tree, near the
  Registry processes.
  """

  use GenServer
  require Logger

  @table :resource_registry

  # ── Public API (callable via Resources) ──

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc false
  def track(owner_pid, kind, id, release_fn) do
    GenServer.call(__MODULE__, {:track, owner_pid, kind, id, release_fn})
  end

  @doc false
  def release(kind, id) do
    GenServer.call(__MODULE__, {:release, kind, id})
  end

  @doc false
  def list_for_owner(owner_pid) do
    case :ets.whereis(@table) do
      :undefined ->
        []

      _ ->
        :ets.tab2list(@table)
        |> Enum.filter(fn {_key, pid, _fn, _ts} -> pid == owner_pid end)
        |> Enum.sort_by(fn {_key, _pid, _fn, ts} -> ts end, :desc)
        |> Enum.map(fn {{kind, id}, pid, _fn, ts} ->
          %{kind: kind, id: id, owner: pid, inserted_at_us: ts}
        end)
    end
  end

  @doc false
  def all do
    case :ets.whereis(@table) do
      :undefined ->
        []

      _ ->
        :ets.tab2list(@table)
        |> Enum.sort_by(fn {_key, _pid, _fn, ts} -> ts end, :desc)
        |> Enum.map(fn {{kind, id}, pid, _fn, ts} ->
          %{
            kind: kind,
            id: id,
            owner: pid,
            owner_alive?: Process.alive?(pid),
            inserted_at_us: ts
          }
        end)
    end
  end

  @doc """
  Testing / debug helper. Forces cleanup for the given owner as if
  DOWN had fired — runs release_fns and deletes rows synchronously.
  Used by tests that can't easily kill a real process (e.g. they
  want to exercise the release path with a self-spawned pid) and by
  `mix boom.rpc` for operator triage.
  """
  def force_release_for_owner(owner_pid) do
    GenServer.call(__MODULE__, {:force_release_for_owner, owner_pid})
  end

  # ── GenServer callbacks ──

  @impl true
  def init(_) do
    # Ensure table exists (StateKeeper creates it at app boot; this
    # covers the standalone-test case where Janitor starts directly).
    BoomLooper.StateKeeper.ensure_tables!()

    # Clean slate every start — any prior monitors are dead with the
    # previous janitor, and ETS rows may reference stale pids from a
    # previous BEAM lifetime if the table survived via StateKeeper.
    # We can't recover monitors, so we must drop entries rather than
    # silently hold "tracked" rows that will never release.
    :ets.delete_all_objects(@table)

    {:ok, %{monitors: %{}, by_owner: %{}}}
  end

  # Track a resource. State tracks:
  #   * monitors: %{pid => ref} — one monitor ref per owner pid
  #   * by_owner: %{pid => MapSet.new([{kind, id}, ...])} — quick lookup
  #     for owner-DOWN teardown without a full ETS scan.
  @impl true
  def handle_call({:track, owner_pid, kind, id, release_fn}, _from, state) do
    key = {kind, id}

    case :ets.lookup(@table, key) do
      [{^key, ^owner_pid, _existing_fn, _ts}] ->
        # Idempotent re-track under the same owner. No-op.
        {:reply, :ok, state}

      [{^key, _other_pid, _fn, _ts}] ->
        # Already tracked under a different owner — refuse. Caller
        # is almost certainly buggy; silent ownership transfer would
        # mean losing the original owner's cleanup.
        {:reply, {:error, :already_tracked}, state}

      [] ->
        # Fresh track. Monitor the owner if we don't already, then
        # insert the ETS row + index entry.
        state = ensure_monitored(state, owner_pid)
        ts = System.monotonic_time(:microsecond)
        :ets.insert(@table, {key, owner_pid, release_fn, ts})
        state = add_to_index(state, owner_pid, key)

        :telemetry.execute(
          [:boom_looper, :resources, :tracked],
          %{count: 1},
          %{kind: kind, owner: owner_pid}
        )

        {:reply, :ok, state}
    end
  end

  def handle_call({:release, kind, id}, _from, state) do
    key = {kind, id}

    case :ets.lookup(@table, key) do
      [{^key, owner_pid, release_fn, _ts}] ->
        run_release(release_fn, kind, id, :explicit)
        :ets.delete(@table, key)
        state = remove_from_index(state, owner_pid, key)
        state = maybe_demonitor(state, owner_pid)
        {:reply, :ok, state}

      [] ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:force_release_for_owner, owner_pid}, _from, state) do
    {state, released} = release_for_owner(state, owner_pid, :explicit)
    {:reply, {:ok, released}, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, owner_pid, _reason}, state) do
    case state.monitors[owner_pid] do
      ^ref ->
        {state, _released} = release_for_owner(state, owner_pid, :owner_down)
        monitors = Map.delete(state.monitors, owner_pid)
        {:noreply, %{state | monitors: monitors}}

      _ ->
        # Stale DOWN (we demonitored earlier) — ignore.
        {:noreply, state}
    end
  end

  # Any other message is not ours; the supervised GenServer stays
  # crash-free rather than raising on unknown mail.
  def handle_info(_msg, state), do: {:noreply, state}

  # ── Internal ──

  defp ensure_monitored(state, owner_pid) do
    case state.monitors[owner_pid] do
      nil ->
        # Small race window: the pid could have died between the
        # caller's track/4 call and this monitor. Process.monitor
        # returns a ref even for dead pids and fires DOWN immediately,
        # so the cleanup still runs — we just fire an :orphan
        # telemetry event to surface that the caller raced us.
        unless Process.alive?(owner_pid) do
          :telemetry.execute(
            [:boom_looper, :resources, :orphan],
            %{count: 1},
            %{owner: owner_pid}
          )
        end

        ref = Process.monitor(owner_pid)
        %{state | monitors: Map.put(state.monitors, owner_pid, ref)}

      _ref ->
        state
    end
  end

  defp add_to_index(state, owner_pid, key) do
    updated =
      Map.update(state.by_owner, owner_pid, MapSet.new([key]), &MapSet.put(&1, key))

    %{state | by_owner: updated}
  end

  defp remove_from_index(state, owner_pid, key) do
    case state.by_owner[owner_pid] do
      nil ->
        state

      set ->
        new_set = MapSet.delete(set, key)

        by_owner =
          if MapSet.size(new_set) == 0 do
            Map.delete(state.by_owner, owner_pid)
          else
            Map.put(state.by_owner, owner_pid, new_set)
          end

        %{state | by_owner: by_owner}
    end
  end

  # Demonitor when an owner has no more tracked resources. Keeps the
  # monitor table bounded — without this, long-running callers that
  # track/release/track would accumulate refs forever.
  defp maybe_demonitor(state, owner_pid) do
    case state.by_owner[owner_pid] do
      nil ->
        case state.monitors[owner_pid] do
          nil ->
            state

          ref ->
            Process.demonitor(ref, [:flush])
            %{state | monitors: Map.delete(state.monitors, owner_pid)}
        end

      _ ->
        state
    end
  end

  defp release_for_owner(state, owner_pid, reason) do
    keys =
      case state.by_owner[owner_pid] do
        nil -> []
        set -> MapSet.to_list(set)
      end

    released =
      for key <- keys do
        case :ets.lookup(@table, key) do
          [{^key, _pid, release_fn, _ts}] ->
            {kind, id} = key
            run_release(release_fn, kind, id, reason)
            :ets.delete(@table, key)
            {kind, id}

          [] ->
            nil
        end
      end
      |> Enum.reject(&is_nil/1)

    by_owner = Map.delete(state.by_owner, owner_pid)
    {%{state | by_owner: by_owner}, released}
  end

  # Run the release function inside a rescue/catch so a buggy release
  # can't take out the janitor or stop other releases from firing.
  defp run_release(nil, kind, id, reason) do
    :telemetry.execute(
      [:boom_looper, :resources, :released],
      %{count: 1},
      %{kind: kind, id: id, reason: reason}
    )
  end

  defp run_release(fun, kind, id, reason) when is_function(fun, 0) do
    try do
      fun.()

      :telemetry.execute(
        [:boom_looper, :resources, :released],
        %{count: 1},
        %{kind: kind, id: id, reason: reason}
      )
    rescue
      e ->
        Logger.warning(
          "[Resources.Janitor] release_fn crashed for #{inspect(kind)}=#{inspect(id)}: " <>
            Exception.message(e)
        )

        :telemetry.execute(
          [:boom_looper, :resources, :released],
          %{count: 1},
          %{kind: kind, id: id, reason: :release_fn_error}
        )
    catch
      :exit, reason_exit ->
        Logger.warning(
          "[Resources.Janitor] release_fn exited for #{inspect(kind)}=#{inspect(id)}: " <>
            inspect(reason_exit)
        )

        :telemetry.execute(
          [:boom_looper, :resources, :released],
          %{count: 1},
          %{kind: kind, id: id, reason: :release_fn_error}
        )
    end
  end

  defp run_release(bad_fn, kind, id, _reason) do
    Logger.warning(
      "[Resources.Janitor] non-zero-arity release_fn for " <>
        "#{inspect(kind)}=#{inspect(id)}: #{inspect(bad_fn)}"
    )

    :telemetry.execute(
      [:boom_looper, :resources, :released],
      %{count: 1},
      %{kind: kind, id: id, reason: :release_fn_error}
    )
  end

  @doc false
  def table, do: @table
end
