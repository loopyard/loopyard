defmodule Loopyard.Fleet.Watch do
  @moduledoc """
  The fleet watch (#119): plain code, no model in the loop. It notices an agent
  that stopped without asking anyone — interrupted by a restart, signed out,
  quarantined, a failed turn nothing retried, its harness offline — raises ONE
  inbox item per agent + condition and settles it when the condition clears,
  and wakes the identity's chief of staff (its default system agent) with ONE
  batched, Loopyard-stamped message naming what it may fix.

  * **Learns** from `Events.ChatAgent` (a coalesced re-sweep a moment after any
    agent event) plus a slow sweep of `Loopyard.Agents.summaries/0` every
    `:fleet_watch_sweep_ms` (default 60 s; nil turns both off, as in test). The
    sweep is ETS reads; the conditions are `Loopyard.Fleet.Conditions`.
  * **Raises** a condition only once it has held for its grace period
    (`:fleet_watch_grace_ms`, `:fleet_watch_offline_grace_ms`), so a backoff
    that heals in seconds, or a just-restored agent about to continue on its
    own (`ChatAgent.Interrupted`), raises nothing.
  * **Wakes** per identity, batched and rate-limited
    (`:fleet_watch_wake_interval_ms`, default 10 min). An open `:plan_limit`
    item is announced too. A condition is announced once; it is forgotten when
    it clears, so a relapse is news again. Never when the chief cannot act: it
    is in trouble itself, its own account is at a plan limit, or the Docker
    disk alert is open at `:down`. Pending announcements wait for it. Off with
    `config :loopyard, fleet_watch_wakes_chief?: false`.

  Delivery (`ensure_running` + `enqueue_message`) runs in a Task; `sync/0`
  waits for it. Test seams: `sweep_now/1` (with `only:` agent ids),
  `:fleet_watch_deliver_fun` (`(system_agent_id, text) -> term`).
  """
  use GenServer
  require Logger

  alias Loopyard.{AccountLimits, Agents, ChatAgent, Notifications, Workstation}
  alias Loopyard.Docker.Disk
  alias Loopyard.Events
  alias Loopyard.Fleet.Conditions
  alias Loopyard.Harness.Catalog
  alias Loopyard.Notifications.Item

  @default_sweep_ms 60_000
  @event_debounce_ms 2_000
  # Older than any grace period: a condition already in the inbox is confirmed.
  @long_ago_ms :timer.hours(24)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Sweep now and wait for it (tests, tools). `only:` limits it to agent ids."
  def sweep_now(opts \\ []), do: GenServer.call(__MODULE__, {:sweep, opts[:only]}, 10_000)

  @doc "Block until any wake in flight has been delivered."
  def sync, do: GenServer.call(__MODULE__, :sync, 20_000)

  @doc "The conditions raised right now, `%{agent_id => condition}`."
  def raised, do: GenServer.call(__MODULE__, :raised, 1_000)

  @impl true
  def init(_opts) do
    if sweep_ms() do
      Events.ChatAgent.subscribe()
      Process.send_after(self(), :sweep, sweep_ms())
    end

    {:ok,
     %{
       seen: %{},
       raised: %{},
       announced: MapSet.new(),
       pending: %{},
       last_wake: %{},
       sweep_armed?: false,
       flush_timer: nil,
       delivering: MapSet.new(),
       waiters: []
     }}
  end

  @impl true
  def handle_call({:sweep, only}, _from, state), do: {:reply, :ok, sweep(state, only)}
  def handle_call(:raised, _from, state), do: {:reply, state.raised, state}

  def handle_call(:sync, from, state) do
    if MapSet.size(state.delivering) == 0,
      do: {:reply, :ok, state},
      else: {:noreply, %{state | waiters: [from | state.waiters]}}
  end

  def handle_call(msg, _from, state) do
    Logger.warning("[Fleet.Watch] unhandled call: #{inspect(msg, limit: 50)}")
    {:reply, {:error, :unknown_call}, state}
  end

  @impl true
  def handle_cast(msg, state) do
    Logger.warning("[Fleet.Watch] unhandled cast: #{inspect(msg, limit: 50)}")
    {:noreply, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    if ms = sweep_ms(), do: Process.send_after(self(), :sweep, ms)
    {:noreply, sweep(state, nil)}
  end

  def handle_info(:event_sweep, state), do: {:noreply, sweep(%{state | sweep_armed?: false}, nil)}
  def handle_info(:flush, state), do: {:noreply, flush(%{state | flush_timer: nil}, now())}

  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, delivered(state, ref)}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, state) do
    if MapSet.member?(state.delivering, ref),
      do: Logger.warning("[Fleet.Watch] wake delivery died: #{inspect(reason, limit: 20)}")

    {:noreply, delivered(state, ref)}
  end

  # Any agent event: look again in a moment (coalesced — a burst is one sweep).
  def handle_info(%{__struct__: _}, %{sweep_armed?: false} = state) do
    Process.send_after(self(), :event_sweep, @event_debounce_ms)
    {:noreply, %{state | sweep_armed?: true}}
  end

  def handle_info(%{__struct__: _}, state), do: {:noreply, state}

  def handle_info(msg, state) do
    Logger.debug("[Fleet.Watch] ignored info: #{inspect(msg, limit: 50)}")
    {:noreply, state}
  end

  # ── the sweep ─────────────────────────────────────────────────────────

  defp sweep(state, only) do
    now = now()
    summaries = Agents.summaries() |> in_scope(only)
    by_id = Map.new(summaries, &{&1.id, &1})

    current =
      for s <- summaries, c = Conditions.of(s), into: %{}, do: {s.id, c}

    # The inbox outlives this process. An item raised before a restart is
    # either still true (then it is already raised and already past its grace
    # period: no second wait, no second item) or it cleared while nobody was
    # watching (then it is settled here; `raised` starts empty, so nothing
    # else would ever settle it).
    {standing, orphaned} = stored(only, current)

    Enum.each(orphaned, fn {aid, c} ->
      Notifications.settle(Conditions.item_id(aid, c), :cleared)
    end)

    seen0 =
      Enum.reduce(standing, scoped(state.seen, only), fn {aid, c}, acc ->
        Map.put_new(acc, {aid, c}, now - @long_ago_ms)
      end)

    raised0 = Map.merge(standing, scoped(state.raised, only))

    {seen, confirmed} = Conditions.observe(seen0, current, now, grace_opts())
    {to_raise, to_settle} = Conditions.changes(raised0, confirmed)

    Enum.each(to_settle, fn {aid, c} ->
      Notifications.settle(Conditions.item_id(aid, c), :cleared)
    end)

    Enum.each(to_raise, fn {aid, c} -> raise_item(by_id[aid], c) end)

    state = %{
      state
      | seen: Map.merge(unscoped(state.seen, only), seen),
        raised: Map.merge(unscoped(state.raised, only), confirmed)
    }

    state
    |> collect(confirmed, by_id, only)
    |> flush(now)
  rescue
    e ->
      Logger.warning("[Fleet.Watch] sweep failed: #{Exception.message(e)}")
      state
  end

  # The open `:stuck` items in scope, split by whether the agent is in that
  # condition right now: `{%{agent_id => condition}, [{agent_id, condition}]}`.
  defp stored(only, current) do
    items =
      for %Item{agent_id: aid, meta: %{condition: c}} <- Notifications.open([:stuck]),
          is_nil(only) or aid in only,
          do: {aid, c}

    {standing, orphaned} = Enum.split_with(items, fn {aid, c} -> Map.get(current, aid) == c end)
    {Map.new(standing), orphaned}
  end

  defp in_scope(summaries, nil), do: summaries
  defp in_scope(summaries, only), do: Enum.filter(summaries, &(&1.id in only))

  # The part of a map keyed by agent (or {agent, _}) inside / outside the scope.
  defp scoped(map, nil), do: map
  defp scoped(map, only), do: Map.filter(map, fn {k, _} -> agent_of(k) in only end)
  defp unscoped(_map, nil), do: %{}
  defp unscoped(map, only), do: Map.reject(map, fn {k, _} -> agent_of(k) in only end)

  defp agent_of({aid, _}), do: aid
  defp agent_of(aid), do: aid

  defp raise_item(nil, _c), do: :ok

  defp raise_item(s, c) do
    who = s[:name] || "An agent"
    account = s[:workstation_identity]
    {act, words} = Conditions.action(c, account)

    Notifications.raise_item(
      Item.stuck(s.id, c, Conditions.label(c, who, account), %{
        action: act,
        action_text: words,
        account: account
      })
    )
  end

  # ── the wake ──────────────────────────────────────────────────────────

  # Every open condition that could be news to a chief of staff: the confirmed
  # ones plus open plan-limit items. Announced keys that cleared are forgotten.
  defp collect(state, confirmed, by_id, only) do
    limits =
      for %Item{agent_id: aid} = i <- Notifications.open([:plan_limit]),
          is_nil(only) or aid in only,
          into: %{},
          do: {aid, {:plan_limit, i.meta[:account]}}

    open =
      Map.new(confirmed, fn {aid, c} -> {{aid, c}, by_id[aid]} end)
      |> Map.merge(Map.new(limits, fn {aid, {k, acct}} -> {{aid, k}, entry(aid, k, acct)} end))

    keys = MapSet.new(Map.keys(open))
    in_scope = fn {aid, _} -> is_nil(only) or aid in only end

    announced =
      MapSet.filter(state.announced, fn k -> not in_scope.(k) or MapSet.member?(keys, k) end)

    pending =
      state.pending
      |> Map.new(fn {ident, entries} ->
        {ident, Map.filter(entries, fn {k, _} -> not in_scope.(k) or MapSet.member?(keys, k) end)}
      end)

    pending =
      if wakes?() do
        Enum.reduce(open, pending, fn {{aid, c} = k, s}, acc ->
          already? = MapSet.member?(announced, k) or Enum.any?(acc, &Map.has_key?(elem(&1, 1), k))

          case {already?, entry(aid, c, s)} do
            {false, %{account: ident} = e} when is_binary(ident) ->
              Map.update(acc, ident, %{k => e}, &Map.put(&1, k, e))

            _ ->
              acc
          end
        end)
      else
        %{}
      end

    %{state | announced: announced, pending: Map.reject(pending, fn {_, e} -> e == %{} end)}
  end

  defp entry(_aid, _c, %{id: _, condition: _} = e), do: e

  defp entry(aid, c, %{} = s),
    do: %{
      id: aid,
      name: s[:name] || "Agent",
      condition: c,
      account: s[:workstation_identity] || Workstation.current()
    }

  defp entry(aid, c, acct) do
    s = Agents.get(aid) || %{}
    %{entry(aid, c, s) | account: acct || s[:workstation_identity] || Workstation.current()}
  end

  defp flush(state, now) do
    interval = wake_interval()

    Enum.reduce(state.pending, state, fn {ident, entries}, st ->
      last = Map.get(st.last_wake, ident)

      if is_nil(last) or now - last >= interval do
        wake(st, ident, entries, now)
      else
        arm_flush(st, last + interval - now)
      end
    end)
  end

  defp wake(state, ident, entries, now) do
    sys_id = Agents.default_id(ident)
    # The chief of staff's own trouble is a reason not to wake it, not news.
    entries = Map.reject(entries, fn {{aid, _}, _} -> aid == sys_id end)

    case {map_size(entries), Conditions.can_wake(wake_ctx(state, ident, sys_id))} do
      {0, _} ->
        %{state | pending: Map.delete(state.pending, ident)}

      {_, :ok} ->
        text = Conditions.wake_text(Map.values(entries))
        state = deliver(state, sys_id, text)

        %{
          state
          | pending: Map.delete(state.pending, ident),
            announced: MapSet.union(state.announced, MapSet.new(Map.keys(entries))),
            last_wake: Map.put(state.last_wake, ident, now)
        }

      {_, {:no, reason}} ->
        Logger.debug("[Fleet.Watch] not waking #{ident}'s chief of staff: #{reason}")
        arm_flush(state, max(wake_interval(), 60_000))
    end
  end

  defp wake_ctx(state, ident, sys_id) do
    system = sys_id && Agents.get(sys_id)

    %{
      enabled?: wakes?(),
      system: system,
      system_condition: system && (Map.get(state.raised, sys_id) || Conditions.of(system)),
      system_limited?:
        is_map(system) and
          AccountLimits.limited?(ident, system[:harness] || Catalog.default()),
      disk_down?:
        match?(%{status: :open, meta: %{level: :down}}, Notifications.get(Disk.alert_id()))
    }
  end

  defp arm_flush(%{flush_timer: ref} = state, _ms) when is_reference(ref), do: state
  defp arm_flush(state, ms), do: %{state | flush_timer: Process.send_after(self(), :flush, ms)}

  defp deliver(state, sys_id, text) do
    fun = Application.get_env(:loopyard, :fleet_watch_deliver_fun, &deliver_to_agent/2)

    %Task{ref: ref} =
      Task.Supervisor.async_nolink(Loopyard.TaskSupervisor, fn -> fun.(sys_id, text) end)

    %{state | delivering: MapSet.put(state.delivering, ref)}
  end

  @doc false
  def deliver_to_agent(sys_id, text) do
    with :ok <- Agents.ensure_running(sys_id), do: ChatAgent.enqueue_message(sys_id, text)
  end

  defp delivered(state, ref) do
    delivering = MapSet.delete(state.delivering, ref)

    if MapSet.size(delivering) == 0 do
      Enum.each(state.waiters, &GenServer.reply(&1, :ok))
      %{state | delivering: delivering, waiters: []}
    else
      %{state | delivering: delivering}
    end
  end

  # ── config ────────────────────────────────────────────────────────────

  defp now, do: System.system_time(:millisecond)
  defp sweep_ms, do: Application.get_env(:loopyard, :fleet_watch_sweep_ms, @default_sweep_ms)
  defp wakes?, do: Application.get_env(:loopyard, :fleet_watch_wakes_chief?, true)

  defp wake_interval,
    do: Application.get_env(:loopyard, :fleet_watch_wake_interval_ms, 10 * 60_000)

  defp grace_opts do
    %{
      grace_ms: Application.get_env(:loopyard, :fleet_watch_grace_ms, 2 * 60_000),
      offline_grace_ms: Application.get_env(:loopyard, :fleet_watch_offline_grace_ms, 5 * 60_000)
    }
  end
end
