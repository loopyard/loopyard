defmodule Loopyard.Notifications do
  @moduledoc """
  The inbox — ONE durable, prioritised store of everything waiting on a human
  (decisions: a question, an approval, a secret request) and, next, of what
  just happened (an agent finished a turn). The team's: multiplayer, anyone
  acts. See plans/notifications-and-agents.md.

  **Why a store.** "What's waiting" used to be a derived query
  (`Loopyard.Attention.line/0`): three broker tables plus a scan of EVERY
  agent's whole message list, on every render of the dashboard, the rail, the
  deck, and inside every push payload — three surfaces, three orders, no
  status, nothing durable. Here an item is raised once, carries its status,
  survives a restart, and is read in O(items).

  **How items get in.** Every card of a decision kind enters through
  `MessageWindow.append_message_ets/2` and settles through
  `MessageWindow.update_message_now/3`; those two funnels call
  `card_raised/2` and `card_status/3`. `Reconcile` sweeps the cards on a slow
  tick (and once after boot) so any path that bypasses the funnels still
  converges: the card is the truth for a decision.

  **Shape.** This GenServer is the single writer; reads go straight to the
  `:notifications` ETS table (owned by `StateKeeper`). Writes are casts —
  the append path of a card must never block on the store. Every change is
  appended to the store's own log (`Notifications.Log`) and broadcast through
  `Events.Notifications`.
  """
  use GenServer
  require Logger

  alias Loopyard.Events
  alias Loopyard.Notifications.{Item, Log, Priority, Reconcile}

  @table :notifications
  @tick_ms 60_000
  @boot_reconcile_ms 5_000
  # Right after boot the agent logs may not have replayed yet, so a missing
  # agent row is not yet evidence the agent is gone.
  @gone_grace_ms 120_000
  # Settled items kept in ETS (and in the compacted log) — enough for a
  # "past decisions" deck, bounded so a long-lived install stays small.
  @keep_settled 500

  # ── reads (direct ETS) ──────────────────────────────────────────────────

  @doc """
  Open items in inbox order (`Priority`). `kinds` narrows: `:all`,
  `:decisions`, or a list of kinds.
  """
  @spec open(:all | :decisions | [Item.kind()]) :: [Item.t()]
  def open(kinds \\ :all) do
    @table
    |> :ets.tab2list()
    |> Enum.map(&elem(&1, 1))
    |> Enum.filter(&(&1.status == :open and kind?(&1, kinds)))
    |> Priority.order()
  rescue
    _ -> []
  end

  @doc "Number of open items (same `kinds` filter as `open/1`)."
  @spec count(:all | :decisions | [Item.kind()]) :: non_neg_integer()
  def count(kinds \\ :all), do: open(kinds) |> length()

  @doc "One item by id, any status."
  @spec get(String.t()) :: Item.t() | nil
  def get(id) do
    case :ets.lookup(@table, id) do
      [{^id, item}] -> item
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc "Settled / dismissed / retracted items, newest settled first."
  @spec recent_settled(pos_integer()) :: [Item.t()]
  def recent_settled(limit \\ 50) do
    @table
    |> :ets.tab2list()
    |> Enum.map(&elem(&1, 1))
    |> Enum.filter(&(&1.status != :open))
    |> Enum.sort_by(&(&1.settled_at || &1.raised_at), {:desc, DateTime})
    |> Enum.take(limit)
  rescue
    _ -> []
  end

  @doc "Every item, any status, unordered."
  @spec all() :: [Item.t()]
  def all do
    @table |> :ets.tab2list() |> Enum.map(&elem(&1, 1))
  rescue
    _ -> []
  end

  # ── writes (casts; the server is the single writer) ─────────────────────

  @doc "A decision card was appended to an agent's transcript."
  def card_raised(agent_id, %{} = msg) do
    case Item.from_card(agent_id, msg) do
      %Item{} = item -> GenServer.cast(__MODULE__, {:raise, item})
      nil -> :ok
    end
  end

  def card_raised(_, _), do: :ok

  @doc "A card's status changed (`:pending` is a no-op; anything else settles)."
  def card_status(agent_id, msg_id, status) when is_binary(agent_id) do
    if status == :pending,
      do: :ok,
      else: GenServer.cast(__MODULE__, {:settle_card, agent_id, msg_id, :settled, status})
  end

  def card_status(_, _, _), do: :ok

  @doc "Raise an arbitrary item (a test fixture). No-op if already open."
  def raise_item(%Item{} = item), do: GenServer.cast(__MODULE__, {:raise, item})

  @doc """
  "Keep going": hand the agent its next prompt (the same path as the
  operator's `dispatch`) and settle the finished item.
  """
  def keep_going(id, text) when is_binary(text) do
    case get(id) do
      %Item{status: :open, agent_id: aid} ->
        with :ok <- Loopyard.ChatAgent.enqueue_message(aid, text) do
          settle(id, :kept_going)
        end

      _ ->
        {:error, :not_open}
    end
  end

  @doc "Settle an item by id with an outcome (acted on)."
  def settle(id, outcome \\ :done),
    do: GenServer.cast(__MODULE__, {:settle, id, :settled, outcome})

  @doc "A human waved the item away."
  def dismiss(id, by \\ nil), do: GenServer.cast(__MODULE__, {:settle, id, :dismissed, by})

  @doc "An agent withdrew the item as moot, with a reason."
  def retract(id, reason), do: GenServer.cast(__MODULE__, {:settle, id, :retracted, reason})

  @doc "Pin / demote / clear an item's priority."
  def prioritise(id, priority) when priority in [:pinned, :demoted, nil],
    do: GenServer.cast(__MODULE__, {:prioritise, id, priority})

  @doc "Run the card sweep now (tests, tools)."
  def reconcile, do: GenServer.cast(__MODULE__, :reconcile)

  @doc "Block until every cast so far has been applied (tests)."
  def sync, do: GenServer.call(__MODULE__, :sync)

  # ── lifecycle ───────────────────────────────────────────────────────────

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    {items, records} = Log.replay()
    Enum.each(items, fn {id, item} -> :ets.insert(@table, {id, item}) end)

    Events.ChatAgent.subscribe()
    Events.Activity.subscribe_global()
    Process.send_after(self(), :boot_reconcile, @boot_reconcile_ms)
    Process.send_after(self(), :tick, @tick_ms)

    {:ok,
     %{
       records: records,
       booted_at: System.monotonic_time(:millisecond),
       reconcile_armed?: false
     }}
  end

  @impl true
  def handle_call(:sync, _from, state), do: {:reply, :ok, state}

  def handle_call(msg, _from, state) do
    Logger.warning("[Notifications] unhandled call: #{inspect(msg, limit: 100)}")
    {:reply, {:error, :unknown_call}, state}
  end

  @impl true
  def handle_cast({:raise, %Item{} = item}, state) do
    case get(item.id) do
      %Item{status: :open} -> {:noreply, state}
      _ -> {:noreply, put(state, %{item | status: :open, settled_at: nil, outcome: nil}, :added)}
    end
  end

  def handle_cast({:settle_card, agent_id, msg_id, status, outcome}, state) do
    case Enum.find(open(), &(&1.agent_id == agent_id and &1.msg_id == msg_id)) do
      %Item{} = item -> {:noreply, settle_item(state, item, status, outcome)}
      nil -> {:noreply, state}
    end
  end

  def handle_cast({:settle, id, status, outcome}, state) do
    case get(id) do
      %Item{status: :open} = item -> {:noreply, settle_item(state, item, status, outcome)}
      _ -> {:noreply, state}
    end
  end

  def handle_cast({:prioritise, id, priority}, state) do
    case get(id) do
      %Item{status: :open} = item ->
        {:noreply, put(state, %{item | priority: priority}, {:changed, :open})}

      _ ->
        {:noreply, state}
    end
  end

  def handle_cast(:reconcile, state), do: {:noreply, run_reconcile(state)}

  def handle_cast(msg, state) do
    Logger.warning("[Notifications] unhandled cast: #{inspect(msg, limit: 100)}")
    {:noreply, state}
  end

  @impl true
  def handle_info(:boot_reconcile, state), do: {:noreply, run_reconcile(state)}

  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, state |> run_reconcile() |> prune() |> maybe_compact()}
  end

  # An agent came back (server restart replayed its log; a workspace booted
  # later than the store did): its pending cards never passed the funnels
  # in THIS process's lifetime, so sweep — coalesced, since a fleet restores
  # in a burst.
  def handle_info(%Events.ChatAgent.Resumed{}, state), do: {:noreply, arm_reconcile(state)}
  def handle_info(%Events.ChatAgent.Started{}, state), do: {:noreply, arm_reconcile(state)}

  def handle_info(:coalesced_reconcile, state),
    do: {:noreply, %{run_reconcile(state) | reconcile_armed?: false}}

  # A WORKSPACE agent finished a turn: one open "finished" item per agent,
  # REPLACED by its next turn rather than stacked. Nothing to say and nothing
  # changed is not an item (Brad: the idle stuff we don't care about). The
  # operator's own turns are not notifications.
  def handle_info(%Events.Activity.Event{kind: :turn_end, workspace_id: ws} = e, state)
      when is_binary(ws) do
    changes = Loopyard.ChangeCounts.get(ws)
    summary = if e.summary in [nil, ""], do: nil, else: e.summary

    if summary || (is_integer(changes) and changes > 0) do
      {:noreply, put_finished(state, e, summary || "finished a turn", changes)}
    else
      {:noreply, state}
    end
  end

  # Back to work → its finished item is moot.
  def handle_info(
        %Events.Activity.Event{kind: :status, summary: "thinking", agent_id: aid},
        state
      ) do
    case get("fin:" <> aid) do
      %Item{status: :open} = item -> {:noreply, settle_item(state, item, :settled, :resumed)}
      _ -> {:noreply, state}
    end
  end

  # An agent removed on purpose: its open items are moot right now, not in
  # two minutes.
  def handle_info(%Events.ChatAgent.Removed{} = e, state) do
    state =
      open()
      |> Enum.filter(&(&1.agent_id == e.id))
      |> Enum.reduce(state, &settle_item(&2, &1, :dismissed, :agent_removed))

    {:noreply, state}
  end

  def handle_info(%{__struct__: mod}, state) when is_atom(mod), do: {:noreply, state}

  def handle_info(msg, state) do
    Logger.warning("[Notifications] unhandled info: #{inspect(msg, limit: 100)}")
    {:noreply, state}
  end

  # ── internals ───────────────────────────────────────────────────────────

  defp put_finished(state, %Events.Activity.Event{} = e, summary, changes) do
    id = "fin:" <> e.agent_id
    prior = get(id)

    item = %Item{
      id: id,
      kind: :finished,
      status: :open,
      agent_id: e.agent_id,
      agent_name: e.agent_name || "Agent",
      workspace_id: e.workspace_id,
      workspace_name: where(e.workspace_id).workspace_name,
      project_id: e.project_id,
      project_name: where(e.workspace_id).project_name,
      path: Item.path(e.workspace_id, e.project_id, e.agent_id),
      msg_id: nil,
      label: summary,
      raised_at: e.at || DateTime.utc_now(),
      meta: %{changes: changes}
    }

    case prior do
      %Item{status: :open} -> put(state, item, {:changed, :open})
      _ -> put(state, item, :added)
    end
  end

  defp where(ws_id) do
    case Loopyard.WorkspaceRegistry.get_workspace(ws_id) do
      %{} = ws ->
        project = ws[:project_id] && Loopyard.ProjectRegistry.get_project(ws[:project_id])
        %{workspace_name: ws[:name], project_name: project && project[:name]}

      _ ->
        %{workspace_name: nil, project_name: nil}
    end
  rescue
    _ -> %{workspace_name: nil, project_name: nil}
  end

  defp settle_item(state, %Item{} = item, status, outcome) do
    from = item.status

    put(
      state,
      %{item | status: status, outcome: outcome, settled_at: DateTime.utc_now()},
      {:changed, from}
    )
  end

  defp put(state, %Item{} = item, event) do
    :ets.insert(@table, {item.id, item})
    Log.append(item)

    case event do
      :added ->
        Events.Notifications.publish(%Events.Notifications.Added{item: item})

      {:changed, from} ->
        Events.Notifications.publish(%Events.Notifications.Changed{item: item, from: from})
    end

    %{state | records: state.records + 1}
  end

  defp arm_reconcile(%{reconcile_armed?: true} = state), do: state

  defp arm_reconcile(state) do
    Process.send_after(self(), :coalesced_reconcile, 250)
    %{state | reconcile_armed?: true}
  end

  defp run_reconcile(state) do
    %{raise: to_raise, settle: to_settle, gone: gone} = Reconcile.diff(open(:decisions))

    state = Enum.reduce(to_raise, state, &put(&2, &1, :added))

    state =
      Enum.reduce(to_settle, state, fn {item, outcome}, s ->
        settle_item(s, item, :settled, outcome)
      end)

    if System.monotonic_time(:millisecond) - state.booted_at > @gone_grace_ms,
      do: Enum.reduce(gone, state, &settle_item(&2, &1, :dismissed, :agent_gone)),
      else: state
  rescue
    e ->
      Logger.warning("[Notifications] reconcile failed: #{Exception.message(e)}")
      state
  end

  # Keep the settled tail bounded in ETS.
  defp prune(state) do
    all()
    |> Enum.filter(&(&1.status != :open))
    |> Enum.sort_by(&(&1.settled_at || &1.raised_at), {:desc, DateTime})
    |> Enum.drop(@keep_settled)
    |> Enum.each(&:ets.delete(@table, &1.id))

    state
  rescue
    _ -> state
  end

  defp maybe_compact(%{records: n} = state) when n > 5_000 do
    Log.compact(all())
    %{state | records: length(all())}
  end

  defp maybe_compact(state), do: state

  defp kind?(_item, :all), do: true
  defp kind?(%Item{kind: k}, :decisions), do: k in Item.decision_kinds()
  defp kind?(%Item{kind: k}, kinds) when is_list(kinds), do: k in kinds
end
