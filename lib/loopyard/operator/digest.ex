defmodule Loopyard.Operator.Digest do
  @moduledoc """
  The operator's completion digest **and** its "tell me when it's done" watches.
  The model: we **feed agents work, they tell us when they're done, so we can put
  them back to work.** A watch is how one dispatched task reports back.

  All of it rides Elixir-side signals, NOT the harness — a sub-agent can't lose a
  notification by crashing or forgetting. A watch reacts to **three** things, so
  the loop never stalls silently:

    1. **Done** — the agent goes `:idle` (`Events.Activity`). Resolve + report the
       result; the operator can re-feed it.
    2. **Needs something** — the agent goes `:awaiting` (it asked a question).
       Surface it ALONG THE WAY so the user can unblock it; keep watching.
    3. **Exits** — the agent process dies (`Process.monitor` `:DOWN`), gracefully
       stopped OR crashed. The stop path publishes a `Stopped` event, not a
       status, and a crash emits nothing on the activity stream — so the monitor
       is the ONLY reliable "it exited" signal. Resolve + report it went down.

  Plus a `@watch_ttl_ms` stall backstop for the (documented) case where none of
  those fire. The `Operator.Jobs` slot is the durable **result** (pull-safe): a
  missed wake never loses the answer, it's still on the board.

  ## Digest (pull)
  A bounded ring of "what just finished" across every workspace, read by the
  `recent_activity` MCP tool. Nothing pushed into the operator's context — it
  pulls on its own cadence. (`:operator_digest` ETS, owned by `StateKeeper`.)

  ## Known limits (documented, not swallowed)
  Every edge degrades to the pull-safe slot, never to a wrong success:

    * **Resolves on the agent's *next* idle** for the "done" signal. In the
      dispatch→notify flow that's the dispatched task (the inbox drains without an
      intermediate idle). Arm it on an agent busy with unrelated work and "done"
      fires when THAT ends.
    * **Arm race:** finishes in the sub-ms window before the watch registers →
      caught by the stall TTL instead.
    * **Delivery race:** the wake is a `{:resume_prompt}` cast that only drives a
      turn if the operator is idle; if it flips busy in that instant the cast is
      dropped — the next tick re-attempts, and the result is on the board anyway.
    * **Digest crash drops in-memory watches** (+ their monitors). Supervised
      restart; results survive in the slot. ETS-backing is the future hardening.
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
  agent finishes (`:idle`), asks for input (`:awaiting`), or exits (process DOWN).
  `ws_id`/`name` are captured for the report text.
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

    # watches: agent_id => %{ws_id, operator_id, name, armed_at, mon}
    #   (mon = the Process.monitor ref for the agent, or nil if it wasn't alive)
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
    # Monitor the agent's process so we hear an EXIT (crash or graceful stop) —
    # the activity stream never carries that. nil if it isn't alive right now
    # (then only :idle/:awaiting/TTL can resolve it).
    mon =
      case Registry.lookup(Loopyard.ChatAgentRegistry, agent_id) do
        [{pid, _}] -> Process.monitor(pid)
        _ -> nil
      end

    watch = %{ws_id: ws_id, operator_id: operator_id, name: name, armed_at: now_ms(), mon: mon}
    {:noreply, put_in(state.watches[agent_id], watch)}
  end

  def handle_cast(_msg, state), do: {:noreply, state}

  # Every agent status change flows here (Events.ChatAgent mirrors StatusChanged
  # into Activity). React to the ones that matter for a watch; keep the digest
  # ring on workspace idles. Everything else (thinking/backoff/…) is ignored.
  @impl true
  def handle_info(%Events.Activity.Event{kind: :status, agent_id: aid, summary: sum} = e, state) do
    state
    |> maybe_digest(e, sum)
    |> react_watch(aid, sum)
    |> maybe_flush(aid, sum)
    |> then(&{:noreply, &1})
  end

  def handle_info(%Events.Activity.Event{}, state), do: {:noreply, state}

  # The watched agent's PROCESS died — the "it exited" signal the status stream
  # can't give us. Resolve the matching watch as an exit (with the reason).
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Enum.find(state.watches, fn {_aid, w} -> w.mon == ref end) do
      {aid, w} ->
        # The monitor already fired; just drop it from state (no demonitor).
        state
        |> stash(w.operator_id, wake_text_exited(w, reason))
        |> Map.update!(:watches, &Map.delete(&1, aid))
        |> try_deliver(w.operator_id)
        |> then(&{:noreply, &1})

      nil ->
        {:noreply, state}
    end
  end

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

  defp maybe_digest(state, %{workspace_id: ws} = e, "idle") when is_binary(ws),
    do: digest_idle(state, e)

  defp maybe_digest(state, _e, _sum), do: state

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

  # --- watch reactions ---

  defp react_watch(state, aid, sum) do
    case Map.get(state.watches, aid) do
      %{} = w -> react(state, aid, w, sum)
      nil -> state
    end
  end

  # Done → resolve + report (and re-feed).
  defp react(state, aid, w, "idle"), do: resolve(state, aid, w, wake_text_done(w))

  # Needs input → surface ALONG THE WAY, keep the watch alive.
  defp react(state, _aid, w, "awaiting"),
    do: state |> stash(w.operator_id, wake_text_awaiting(w)) |> try_deliver(w.operator_id)

  defp react(state, _aid, _w, _sum), do: state

  # Remove a watch (demonitoring its process monitor) and stash its wake.
  defp resolve(state, aid, w, text) do
    if w.mon, do: Process.demonitor(w.mon, [:flush])

    state
    |> stash(w.operator_id, text)
    |> Map.update!(:watches, &Map.delete(&1, aid))
    |> try_deliver(w.operator_id)
  end

  defp sweep_stalled(state) do
    cutoff = now_ms() - @watch_ttl_ms

    Enum.reduce(state.watches, state, fn
      {aid, %{armed_at: at} = w}, acc when at < cutoff ->
        resolve(acc, aid, w, wake_text_stalled(w))

      {_aid, _w}, acc ->
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

  defp maybe_flush(state, aid, "idle"), do: flush_pending(state, aid)
  defp maybe_flush(state, _aid, _sum), do: state

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

  # --- wake texts ---

  defp wake_text_done(w) do
    delta = Jobs.delta(Jobs.get(w.ws_id))

    produced =
      if delta > 0,
        do: "It produced #{delta} new message(s).",
        else: "It finished but produced nothing new."

    "[auto-notify] A task you were watching just finished in workspace " <>
      "\"#{w.name}\". #{produced} Pull the result (peek_workspace / recent_activity " <>
      "for #{w.ws_id}) and tell the user, concisely, what got done — and if there's " <>
      "an obvious next task, tee it up (we keep agents fed). You can stop watching it now."
  end

  defp wake_text_awaiting(w) do
    "[auto-notify] The task you're watching in workspace \"#{w.name}\" is WAITING ON " <>
      "INPUT — it asked a question and is blocked until answered. Point the user to it " <>
      "(the /queue town hall, or its workspace chat) so it can keep going. Still " <>
      "watching — I'll tell you when it finishes."
  end

  defp wake_text_exited(w, reason) do
    how =
      case reason do
        r when r in [:normal, :shutdown] -> "was stopped"
        {:shutdown, _} -> "was shut down"
        _ -> "crashed (#{inspect(reason, limit: 5)})"
      end

    "[auto-notify] The agent you were watching in workspace \"#{w.name}\" #{how} before " <>
      "finishing. Tell the user it went down, and offer to restart it / check its logs, " <>
      "or re-dispatch the task."
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
