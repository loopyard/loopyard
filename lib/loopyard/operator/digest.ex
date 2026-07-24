defmodule Loopyard.Operator.Digest do
  @moduledoc """
  The operator's completion digest **and** its "tell me when it's done" watches —
  both ride the one Elixir seam that fires when a workspace agent finishes a turn
  (`Events.Activity`, `kind: :status, summary: "idle"`). Crucially this hook lives
  in Loopyard, NOT in the harness: "done" = Loopyard observing the agent go idle,
  so it can't be lost by a sub-agent forgetting to call something or crashing
  mid-turn.

  ## Digest (pull)
  A bounded ring of "what just finished" across every workspace, read by the
  `recent_activity` MCP tool. Nothing is pushed into the operator's context — it
  pulls on its own cadence. (`:operator_digest` ETS, owned by `StateKeeper`.)

  ## Watches (push — "tell me when it's done")
  The operator arms a watch on a workspace it dispatched to (`watch/4`, via the
  `notify_when_done` tool). The watch is the **trigger**; the `Operator.Jobs` slot
  is the durable **result** (pull-safe — even if a wake is missed, the result
  still sits in the slot on the board). Three terminal states:

    * the agent goes idle having produced work (delta > 0) → **done**: wake the
      operator to report the result;
    * idle having produced nothing (delta 0) → **done, empty**: still wake, "it
      finished but produced nothing";
    * never resolves within `@watch_ttl_ms` → **stalled**: wake the operator that
      the dispatch appears dead. (The self-decay we let happen everywhere else.)

  The wake is a silent `{:resume_prompt, …}` cast — it drives one operator turn
  without a visible "user" message, so the operator just speaks up with the
  result. If the operator is busy, the wake is stashed and flushed on its next
  idle (so a busy operator never drops the notification).

  Config-gated (`:operator_digest_enabled?`, off in test).
  """
  use GenServer
  require Logger

  alias Loopyard.Events
  alias Loopyard.Operator.Jobs

  @table :operator_digest
  @max 100

  # How long a dispatch may run before an unresolved watch is called stalled.
  @watch_ttl_ms 20 * 60 * 1000
  @tick_ms 60 * 1000

  # --- Read API (ETS-only; safe to call from anywhere, incl. the MCP tool) ---

  @doc "Recent cross-workspace completions, NEWEST first (up to `limit`)."
  @spec recent(pos_integer()) :: [map()]
  def recent(limit \\ 20) when is_integer(limit) and limit > 0 do
    :ets.tab2list(@table)
    |> Enum.sort_by(fn {seq, _} -> seq end, :desc)
    |> Enum.take(limit)
    |> Enum.map(fn {_seq, entry} -> entry end)
  rescue
    _ -> []
  end

  @doc """
  The agents currently being watched — a live registry of "what the operator is
  waiting on". `[%{ws_id, agent_id, name, armed_at}]`. Short call timeout with an
  empty fallback so a busy Digest never blocks a render.
  """
  @spec watches() :: [map()]
  def watches do
    GenServer.call(__MODULE__, :watches, 200)
  catch
    :exit, _ -> []
  end

  @doc """
  Arm a "tell me when it's done" watch: wake `operator_id` when the agent in
  `ws_id` next finishes a turn (or stalls). `name` is the workspace's display
  name (captured at arm time so the wake reads well).
  """
  @spec watch(String.t(), String.t(), String.t(), String.t()) :: :ok
  def watch(ws_id, agent_id, operator_id, name)
      when is_binary(ws_id) and is_binary(agent_id) and is_binary(operator_id) do
    GenServer.cast(__MODULE__, {:watch, ws_id, agent_id, operator_id, name})
  end

  # --- Lifecycle ---

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    if enabled?() do
      Events.Activity.subscribe_global()
      Process.send_after(self(), :tick, @tick_ms)
    end

    # watches: ws_id => %{agent_id, operator_id, name, armed_at}
    # pending: operator_id => [wake_text]  (stashed while the operator is busy)
    {:ok, %{seq: 0, last: nil, watches: %{}, pending: %{}}}
  end

  @impl true
  def handle_call(:watches, _from, state) do
    list =
      Enum.map(state.watches, fn {ws_id, w} ->
        %{ws_id: ws_id, agent_id: w.agent_id, name: w.name, armed_at: w.armed_at}
      end)

    {:reply, list, state}
  end

  @impl true
  def handle_cast({:watch, ws_id, agent_id, operator_id, name}, state) do
    watch = %{agent_id: agent_id, operator_id: operator_id, name: name, armed_at: now_ms()}
    {:noreply, put_in(state.watches[ws_id], watch)}
  end

  def handle_cast(_msg, state), do: {:noreply, state}

  # A workspace agent finished a turn (idle). Digest + resolve any watch on it.
  @impl true
  def handle_info(
        %Events.Activity.Event{kind: :status, summary: "idle", workspace_id: ws} = e,
        state
      )
      when is_binary(ws) do
    state
    |> digest_idle(e)
    |> resolve_watch(ws, e.agent_id)
    |> then(&{:noreply, &1})
  end

  # An idle event with no workspace = the operator itself going idle → a chance to
  # flush any wake we stashed while it was busy.
  def handle_info(%Events.Activity.Event{kind: :status, summary: "idle", agent_id: aid}, state),
    do: {:noreply, flush_pending(state, aid)}

  def handle_info(%Events.Activity.Event{}, state), do: {:noreply, state}

  # TTL sweep: any watch that never resolved is presumed stalled — wake the
  # operator that the dispatch appears dead, then drop it (self-decay).
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, @tick_ms)
    cutoff = now_ms() - @watch_ttl_ms

    Enum.reduce(state.watches, state, fn
      {ws_id, %{armed_at: at} = w}, acc when at < cutoff ->
        acc
        |> stash(w.operator_id, wake_text_stalled(w))
        |> update_in([:watches], &Map.delete(&1, ws_id))
        |> try_deliver(w.operator_id)

      {_ws_id, _w}, acc ->
        acc
    end)
    |> then(&{:noreply, &1})
  end

  # Catchall (project rule): unknown messages never crash the GenServer.
  def handle_info(msg, state) do
    Logger.warning("[Operator.Digest] unhandled info: #{inspect(msg, limit: 100)}")
    {:noreply, state}
  end

  # --- digest ring ---

  defp digest_idle(state, e) do
    key = {e.agent_id, :idle}

    if state.last == key do
      # Dedupe a repeated idle from the SAME agent back-to-back (no new turn).
      state
    else
      seq = state.seq + 1

      entry = %{
        agent_id: e.agent_id,
        agent_name: e.agent_name,
        workspace_id: e.workspace_id,
        project_id: e.project_id,
        summary: "finished a turn",
        at: e.at
      }

      :ets.insert(@table, {seq, entry})
      if seq > @max, do: :ets.delete(@table, seq - @max)
      %{state | seq: seq, last: key}
    end
  end

  # --- watch resolution ---

  defp resolve_watch(state, ws_id, agent_id) do
    case Map.get(state.watches, ws_id) do
      %{agent_id: ^agent_id} = w ->
        state
        |> stash(w.operator_id, wake_text_done(ws_id, w))
        |> update_in([:watches], &Map.delete(&1, ws_id))
        |> try_deliver(w.operator_id)

      _ ->
        state
    end
  end

  # Stash a wake for the operator (combined into one turn when delivered).
  defp stash(state, operator_id, text),
    do: update_in(state.pending[operator_id], &[text | &1 || []])

  # Deliver stashed wakes IF the operator is idle right now; otherwise leave them
  # to flush on its next idle. Combined into a single prompt so we drive one turn.
  defp try_deliver(state, operator_id) do
    texts = Map.get(state.pending, operator_id, [])

    if texts != [] and operator_idle?(operator_id) do
      cast_wake(operator_id, Enum.join(Enum.reverse(texts), "\n\n"))
      update_in(state.pending, &Map.delete(&1, operator_id))
    else
      state
    end
  end

  defp flush_pending(state, agent_id) do
    if Map.has_key?(state.pending, agent_id), do: try_deliver(state, agent_id), else: state
  end

  defp operator_idle?(operator_id) do
    case Loopyard.ChatAgent.get_state(operator_id) do
      %{status: :idle} -> true
      _ -> false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp cast_wake(operator_id, text) do
    case Registry.lookup(Loopyard.ChatAgentRegistry, operator_id) do
      [{pid, _}] -> GenServer.cast(pid, {:resume_prompt, text})
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  defp wake_text_done(ws_id, w) do
    delta = Jobs.delta(Jobs.get(ws_id))

    produced =
      if delta > 0,
        do: "It produced #{delta} new message(s).",
        else: "It finished but produced nothing new."

    "[auto-notify] A task you were watching just finished in workspace " <>
      "\"#{w.name}\". #{produced} Pull the result (peek_workspace / recent_activity " <>
      "for #{ws_id}) and tell the user, concisely, what got done. You can stop " <>
      "watching it now."
  end

  defp wake_text_stalled(w) do
    "[auto-notify] The task you were watching in workspace \"#{w.name}\" hasn't " <>
      "finished in #{div(@watch_ttl_ms, 60_000)} minutes and appears stalled. Tell " <>
      "the user it looks stuck, and suggest a next step (restart the agent, check " <>
      "its logs, or let it go)."
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp enabled?, do: Application.get_env(:loopyard, :operator_digest_enabled?, true)
end
