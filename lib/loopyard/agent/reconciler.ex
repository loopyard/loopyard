defmodule Loopyard.Agent.Reconciler do
  @moduledoc """
  Periodic reconciler for the agent registry + ETS cache. Detects
  drift between what `:chat_agents` ETS thinks is alive and what the
  `Loopyard.ChatAgentRegistry` says is actually alive.

  Move #6 of plans/coordination-hardening.md (narrowed scope — Docker
  reconciler ships via Observer, workspace reconciler deferred).

  ## What drift means here

  The ETS summary carries a `:status` field (`:idle`, `:thinking`,
  `:booting`, `:crashed`, `:stopped`, `:destroying`). The Registry
  is the authoritative "is the GenServer alive right now" source.
  When they disagree, one of them is wrong:

    * **ETS says alive, Registry says dead** — the most common drift.
      A status broadcast got dropped, a supervisor restart happened
      without the log catching it, etc. We correct ETS to `:crashed`
      (structurally more accurate: the agent is no longer running).
      This fixes the "sleepy agent" class where the UI shows :idle
      but no process exists.

    * **ETS says stopped, Registry says alive** — suspicious. A
      zombie process, or someone started an agent out-of-band. We
      log and telemetry-flag but don't auto-correct — the right
      response is investigation, not blind mutation.

    * **ETS says destroying, Registry says alive** — the removal
      path crashed midway. Not auto-correcting here either; the
      destroying state is a transient and the in-flight remove
      should retry or get cleaned up by the parent supervisor.

  ## Timing

  Default: scan every 30s. Cheap (one ETS tab2list + one Registry
  lookup per entry). Configurable via application env for tests:

      Application.put_env(:loopyard, :agent_reconciler_interval_ms, 200)

  ## Observability

  Every drift instance fires:

    * `:telemetry.execute([:loopyard, :reconcile, :drift], ...)`
    * A `:chat_agent_status_changed` broadcast (for UI refresh when
      we corrected ETS)
    * An EventLog entry at `:warning` level so drift is human-readable

  Every full scan (whether drift found or not) fires:

    * `:telemetry.execute([:loopyard, :reconcile, :run], %{
        duration_ms: d, drift_count: n, checked: k
      }, %{reconciler: :agents})`
  """

  use GenServer
  require Logger

  @default_interval_ms 30_000

  # ── Public API ──

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc """
  Force an immediate reconciliation pass. Useful for tests and for
  `mix loopyard.rpc` debugging ("something looks off, run the reconciler
  now"). Returns the scan result synchronously.
  """
  def reconcile_now do
    GenServer.call(__MODULE__, :reconcile_now, 10_000)
  end

  @doc """
  Last reconciliation summary. Populated after every scan.
  Returns `nil` before the first run.
  """
  def last_run do
    GenServer.call(__MODULE__, :last_run, 2_000)
  end

  # ── GenServer ──

  @impl true
  def init(_) do
    schedule_next()
    {:ok, %{last_run: nil}}
  end

  @impl true
  def handle_info(:tick, state) do
    schedule_next()
    result = do_reconcile()
    {:noreply, %{state | last_run: result}}
  end

  def handle_info(msg, state) do
    Logger.warning("[Agent.Reconciler] unhandled: #{inspect(msg, limit: 200)}")

    :telemetry.execute(
      [:loopyard, :actor, :unknown_message],
      %{count: 1},
      %{actor: __MODULE__, msg: inspect(msg, limit: 200)}
    )

    {:noreply, state}
  end

  @impl true
  def handle_call(:reconcile_now, _from, state) do
    result = do_reconcile()
    {:reply, result, %{state | last_run: result}}
  end

  def handle_call(:last_run, _from, state) do
    {:reply, state.last_run, state}
  end

  # ── Reconciliation ──

  defp do_reconcile do
    start_us = System.monotonic_time(:microsecond)

    entries = :ets.tab2list(:chat_agents)

    {drifts, checked} =
      Enum.reduce(entries, {[], 0}, fn {id, summary}, {drifts_acc, checked_acc} ->
        drift = check_entry(id, summary)
        drifts_acc = if drift, do: [drift | drifts_acc], else: drifts_acc
        {drifts_acc, checked_acc + 1}
      end)

    # Apply corrections AFTER we've iterated the table — mutating
    # ETS mid-iteration is error-prone with ordered_set semantics
    # even when the table isn't ordered_set.
    Enum.each(drifts, &apply_correction/1)

    duration_ms = div(System.monotonic_time(:microsecond) - start_us, 1000)

    result = %{
      ran_at: DateTime.utc_now(),
      duration_ms: duration_ms,
      checked: checked,
      drift_count: length(drifts),
      drifts: drifts
    }

    :telemetry.execute(
      [:loopyard, :reconcile, :run],
      %{duration_ms: duration_ms, drift_count: length(drifts), checked: checked},
      %{reconciler: :agents}
    )

    if drifts != [] do
      Loopyard.EventLog.warning(
        "reconciler:agents",
        "drift=#{length(drifts)}/#{checked} ids=#{drift_ids(drifts)}"
      )
    end

    result
  end

  # Returns `nil` if the entry is consistent, or a drift tuple if
  # correction is warranted.
  defp check_entry(id, summary) do
    status = Map.get(summary, :status)
    alive = agent_alive?(id)

    cond do
      # Alive-according-to-status, dead-according-to-Registry. The
      # canonical drift: correct to :crashed.
      status in [:idle, :thinking, :booting] and not alive ->
        {:stale_alive, id, summary, status}

      # Registry has a live pid but ETS claims stopped/destroying.
      # Log and flag — don't auto-correct; this is weird enough
      # that a human should look at it.
      status in [:stopped, :destroying] and alive ->
        {:zombie, id, summary, status}

      true ->
        nil
    end
  end

  defp apply_correction({:stale_alive, id, summary, old_status}) do
    # TOCTOU guard: corrections are applied AFTER the full scan, so an agent
    # can respawn (RestartController / resume) between check_entry and here.
    # Re-check liveness and re-read the row so we never clobber a fresh
    # summary with the stale snapshot marked :crashed.
    if agent_alive?(id) do
      :ok
    else
      current = current_summary(id) || summary
      corrected = %{current | status: :crashed}
      :ets.insert(:chat_agents, {id, corrected})

      Loopyard.Events.ChatAgent.publish(%Loopyard.Events.ChatAgent.StatusChanged{
        id: id,
        status: :crashed
      })

      :telemetry.execute(
        [:loopyard, :reconcile, :drift],
        %{count: 1},
        %{kind: :stale_alive, agent_id: id, before: old_status, after: :crashed, corrected: true}
      )
    end
  end

  defp apply_correction({:zombie, id, _summary, status}) do
    # No ETS mutation — just telemetry + log so operators see it.
    :telemetry.execute(
      [:loopyard, :reconcile, :drift],
      %{count: 1},
      %{kind: :zombie, agent_id: id, ets_status: status, registry: :alive, corrected: false}
    )

    Loopyard.EventLog.warning(
      "reconciler:agents",
      "zombie agent #{id}: ETS=#{status} but Registry has live pid (not auto-corrected)"
    )
  end

  defp agent_alive?(id) do
    case Registry.lookup(Loopyard.ChatAgentRegistry, id) do
      [{pid, _}] -> Process.alive?(pid)
      _ -> false
    end
  rescue
    _ -> false
  end

  defp current_summary(id) do
    case :ets.lookup(:chat_agents, id) do
      [{^id, summary}] -> summary
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp drift_ids(drifts) do
    drifts
    |> Enum.map(fn tuple -> elem(tuple, 1) end)
    |> Enum.join(",")
  end

  defp schedule_next do
    Process.send_after(self(), :tick, interval_ms())
  end

  defp interval_ms do
    Application.get_env(:loopyard, :agent_reconciler_interval_ms, @default_interval_ms)
  end
end
