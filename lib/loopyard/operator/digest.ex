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
  The operator arms a watch on an agent it dispatched to (`watch/4`, via the
  `notify_when_done` tool). The watch is the **trigger**; the `Operator.Jobs` slot
  is the durable **result** (pull-safe — even if a wake is missed the result still
  sits in the slot on the board). Watches are keyed by **agent_id** (the thing
  that goes idle), never by workspace — one workspace can hold more than one
  agent, and matching by workspace would let two watches clobber each other.

  Terminal states:

    * agent goes idle having produced work (delta > 0) → **done** (report result);
    * idle having produced nothing (delta 0) → **done, empty**;
    * unresolved after `@watch_ttl_ms` → **stalled** (dispatch looks dead — the
      self-decay we allow everywhere else).

  ## Known limits (documented, not swallowed)
  These are real edges — surfaced here rather than hidden, and every one degrades
  to the pull-safe slot, never to a wrong success:

    * **Resolves on the agent's *next* idle.** In the dispatch→notify flow that's
      the dispatched task (the inbox drains without an intermediate idle). Arm it
      on an agent already busy with unrelated work and it fires when THAT ends.
    * **Arm race:** if the agent finishes in the sub-ms window between the tool
      reading its status and the watch registering, it resolves via the stall TTL
      instead. Rare; still pull-safe.
    * **Delivery race:** the wake is a `{:resume_prompt}` cast that only drives a
      turn if the operator is idle; if it flips busy in that instant the cast is
      dropped. The result is still on the board, and the next tick re-attempts.
    * **Digest crash drops in-memory watches.** Supervised restart; watches are
      lost but results aren't (slot). ETS-backing is the hardening if we ever
      want cross-crash durability.
    * **One watch per agent** (last arm wins) — single-operator assumption.

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
    # ETS read boundary: a missing table on a race shouldn't crash a caller's
    # render. A genuinely absent StateKeeper table is loud on its own (boot).
    _ -> []
  end

  @doc """
  The agents currently being watched — a live registry of "what the operator is
  waiting on". `[%{ws_id, agent_id, name, armed_at}]`. Short call timeout with an
  empty fallback: this is a render read, and a momentarily-busy Digest must not
  crash the operator page. Digest being genuinely DOWN is loud via its supervisor.
  """
  @spec watches() :: [map()]
  def watches do
    GenServer.call(__MODULE__, :watches, 200)
  catch
    :exit, _ -> []
  end

  @doc """
  Arm a "tell me when it's done" watch on `agent_id`: wake `operator_id` when that
  agent next finishes a turn (or stalls). `ws_id`/`name` are captured for the
  report text.
  """
  @spec watch(String.t(), String.t(), String.t(), String.t()) :: :ok
  def watch(ws_id, agent_id, operator_id, name)
      when is_binary(ws_id) and is_binary(agent_id) and is_binary(operator_id) and
             is_binary(name) do
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

    # watches: agent_id => %{ws_id, operator_id, name, armed_at}
    # pending: operator_id => [wake_text]  (stashed while the operator is busy)
    {:ok, %{seq: 0, last: nil, watches: %{}, pending: %{}}}
  end

  @impl true
  def handle_call(:watches, _from, state) do
    list =
      Enum.map(state.watches, fn {agent_id, w} ->
        %{ws_id: w.ws_id, agent_id: agent_id, name: w.name, armed_at: w.armed_at}
      end)

    {:reply, list, state}
  end

  @impl true
  def handle_cast({:watch, ws_id, agent_id, operator_id, name}, state) do
    watch = %{ws_id: ws_id, operator_id: operator_id, name: name, armed_at: now_ms()}
    {:noreply, put_in(state.watches[agent_id], watch)}
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
    |> resolve_watch(e.agent_id)
    |> then(&{:noreply, &1})
  end

  # An idle event with no workspace = the operator itself going idle → flush any
  # wake we stashed while it was busy.
  def handle_info(%Events.Activity.Event{kind: :status, summary: "idle", agent_id: aid}, state),
    do: {:noreply, flush_pending(state, aid)}

  def handle_info(%Events.Activity.Event{}, state), do: {:noreply, state}

  # TTL sweep + delivery retry + leak cleanup, once a minute.
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, @tick_ms)

    state
    |> sweep_stalled()
    |> retry_all_pending()
    |> drop_dead_pending()
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

  defp resolve_watch(state, agent_id) do
    case Map.get(state.watches, agent_id) do
      %{} = w ->
        state
        |> stash(w.operator_id, wake_text_done(w))
        |> Map.update!(:watches, &Map.delete(&1, agent_id))
        |> try_deliver(w.operator_id)

      nil ->
        state
    end
  end

  defp sweep_stalled(state) do
    cutoff = now_ms() - @watch_ttl_ms

    Enum.reduce(state.watches, state, fn
      {agent_id, %{armed_at: at} = w}, acc when at < cutoff ->
        acc
        |> stash(w.operator_id, wake_text_stalled(w))
        |> Map.update!(:watches, &Map.delete(&1, agent_id))
        |> try_deliver(w.operator_id)

      {_agent_id, _w}, acc ->
        acc
    end)
  end

  # --- delivery ---

  # Stash a wake for the operator (combined into one turn when delivered).
  defp stash(state, operator_id, text),
    do: update_in(state.pending[operator_id], &[text | &1 || []])

  # Deliver stashed wakes IF the operator is idle right now; else leave them to
  # flush on its next idle (or the next tick). One combined prompt = one turn.
  defp try_deliver(state, operator_id) do
    texts = Map.get(state.pending, operator_id, [])

    if texts != [] and operator_idle?(operator_id) do
      cast_wake(operator_id, Enum.join(Enum.reverse(texts), "\n\n"))
      Map.update!(state, :pending, &Map.delete(&1, operator_id))
    else
      state
    end
  end

  defp flush_pending(state, agent_id) do
    if Map.has_key?(state.pending, agent_id), do: try_deliver(state, agent_id), else: state
  end

  defp retry_all_pending(state),
    do: Enum.reduce(Map.keys(state.pending), state, &try_deliver(&2, &1))

  # Bound the leak + surface it: an operator whose process is gone can never take
  # delivery — drop its stashed wakes loudly rather than growing forever.
  defp drop_dead_pending(state) do
    {dead, alive} = Enum.split_with(state.pending, fn {op, _} -> not agent_alive?(op) end)

    for {op, texts} <- dead do
      Logger.warning(
        "[Operator.Digest] dropping #{length(texts)} undeliverable wake(s) for dead operator #{op}"
      )
    end

    %{state | pending: Map.new(alive)}
  end

  # get_state catches its own timeouts/noproc and returns a summary or nil, so it
  # doesn't raise — no defensive wrapper here (an unexpected raise SHOULD surface).
  defp operator_idle?(operator_id),
    do: match?(%{status: :idle}, Loopyard.ChatAgent.get_state(operator_id))

  defp agent_alive?(agent_id) do
    case Registry.lookup(Loopyard.ChatAgentRegistry, agent_id) do
      [{pid, _}] -> Process.alive?(pid)
      _ -> false
    end
  end

  defp cast_wake(operator_id, text) do
    case Registry.lookup(Loopyard.ChatAgentRegistry, operator_id) do
      [{pid, _}] -> GenServer.cast(pid, {:resume_prompt, text})
      _ -> :ok
    end
  end

  defp wake_text_done(w) do
    delta = Jobs.delta(Jobs.get(w.ws_id))

    produced =
      if delta > 0,
        do: "It produced #{delta} new message(s).",
        else: "It finished but produced nothing new."

    "[auto-notify] A task you were watching just finished in workspace " <>
      "\"#{w.name}\". #{produced} Pull the result (peek_workspace / recent_activity " <>
      "for #{w.ws_id}) and tell the user, concisely, what got done. You can stop " <>
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
