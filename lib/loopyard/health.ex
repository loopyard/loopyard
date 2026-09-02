defmodule Loopyard.Health do
  @moduledoc """
  Flat component-health map. Lets the UI distinguish "Loopyard is
  broken" from "an upstream dependency is unavailable" — on a Docker
  daemon outage the affected features render degraded banners rather
  than going blank and looking like app bugs.

  Move #11 of plans/archive/coordination-hardening.md (narrowed scope — flat
  map, no dependency graph). Components get added as they earn the
  overhead; starting with the handful that have real health signals:

    * `:docker` — from `Loopyard.Docker.Observer.health/0`
    * `:pubsub` — Phoenix.PubSub running means we can broadcast,
      which covers every cross-process signal path in Loopyard
    * `:agent_reconciler` — last-run age from Agent.Reconciler

  ## Status shape

  Each component reports one of:

    * `:healthy`
    * `{:degraded, reason :: String.t()}`
    * `{:down, reason :: String.t()}`

  "Degraded" means the component is partially working and the system
  should adapt (show a stale badge, queue operations, etc). "Down"
  means nothing from that component can be trusted right now.

  ## No dependency graph

  Components don't declare dependencies on each other. A UI layer
  that cares about "Docker is down → ChatAgent probably can't
  exec" figures that out itself from the flat map. Keeping this
  layer flat is deliberate — a component-dependency framework is
  premature for our population of 3.
  """

  @components [:docker, :pubsub, :agent_reconciler]

  # Drift is the reconciler's JOB — transient `:booting → :crashed`
  # blips during agent lifecycle produce drift of 1 or 2 per scan.
  # A false-positive "degraded" banner every agent boot is worse
  # than no banner at all. Only flag degraded when drift is above
  # a meaningful threshold (indicating agents are actually dying in
  # bulk, not just a single transient blip).
  @drift_degraded_threshold 5

  # Reconciler scans every 30s; flag degraded when the last scan
  # is too stale (reconciler stuck, crashed, or interval nuked).
  @reconciler_stale_secs 120

  @doc "Every component we report on."
  def components, do: @components

  @doc """
  Aggregate health across all components. Returns a map
  `%{component => status}`.
  """
  def overall do
    Map.new(@components, fn comp -> {comp, component(comp)} end)
  end

  @doc """
  Health of a single component. Returns one of `:healthy`,
  `{:degraded, reason}`, `{:down, reason}`.
  """
  def component(:docker) do
    h = Loopyard.Docker.Observer.health()

    cond do
      h.connected and h.snapshot_failures == 0 ->
        :healthy

      h.connected and h.snapshot_failures > 0 ->
        {:degraded, "#{h.snapshot_failures} consecutive snapshot failures — reconciler retrying"}

      h.connected == false and h.last_snapshot_at == nil ->
        {:down, "Docker daemon unreachable — no snapshot has ever succeeded"}

      h.connected == false ->
        secs_ago = DateTime.diff(DateTime.utc_now(), h.last_snapshot_at)

        {:degraded, "Event stream disconnected — last snapshot #{secs_ago}s ago, cache retained"}

      true ->
        :healthy
    end
  rescue
    _ -> {:down, "Observer raised during health check"}
  catch
    :exit, _ -> {:down, "Observer GenServer unresponsive"}
  end

  def component(:pubsub) do
    # PubSub is a supervised dependency. If the supervised process
    # is alive, the transport works. If it's not, we couldn't even
    # broadcast this module was loaded, so reaching this code path
    # at all is evidence of health — but we check anyway for
    # completeness in case the supervisor is mid-restart.
    case Process.whereis(Loopyard.PubSub) do
      nil -> {:down, "Phoenix.PubSub supervisor not registered"}
      pid -> if Process.alive?(pid), do: :healthy, else: {:down, "PubSub supervisor dead"}
    end
  end

  def component(:agent_reconciler) do
    case Loopyard.Agent.Reconciler.last_run() do
      nil ->
        # Just booted — no scan yet. Healthy default.
        :healthy

      %{ran_at: ran_at, drift_count: drift_count} ->
        secs_ago = DateTime.diff(DateTime.utc_now(), ran_at)
        # Reconciler scans every 30s; if the last run is too stale,
        # something's wrong with it (stuck, crashed, or the interval
        # got nuked).
        #
        # For drift: the reconciler's job is to detect + correct
        # drift, so any non-zero count is NORMAL during an agent
        # boot blip. Only report degraded when drift exceeds a
        # threshold (bulk failures, not a single transient).
        cond do
          secs_ago > @reconciler_stale_secs ->
            {:degraded, "Last scan #{secs_ago}s ago (reconciler should tick every 30s)"}

          drift_count > @drift_degraded_threshold ->
            {:degraded,
             "Last scan corrected #{drift_count} drift(s) — agents are dying unexpectedly"}

          true ->
            :healthy
        end
    end
  catch
    :exit, _ -> {:down, "Agent.Reconciler GenServer unresponsive"}
  end

  @doc """
  One-line severity across all components. Useful for UI badges.

  Returns `:healthy` if every component is healthy, `:degraded` if
  any is degraded (but none down), `:down` if any are down.
  """
  def severity do
    statuses = overall() |> Map.values()

    cond do
      Enum.any?(statuses, &match?({:down, _}, &1)) -> :down
      Enum.any?(statuses, &match?({:degraded, _}, &1)) -> :degraded
      true -> :healthy
    end
  end

  @doc """
  Human-readable status word. `:healthy` → \"healthy\", tuples show
  the reason.
  """
  def format(:healthy), do: "healthy"
  # Bare severity atoms (from `severity/0`) as well as the {status, reason}
  # component tuples (from `component/1`) — format/1 must speak BOTH, since both
  # flow into system_status. Missing the bare forms is what crashed it.
  def format(:degraded), do: "degraded"
  def format(:down), do: "down"
  def format({:degraded, reason}), do: "degraded — #{reason}"
  def format({:down, reason}), do: "down — #{reason}"
  # Never crash a health read on an unexpected shape — a status label is not
  # worth taking down the whole system_status tool (that's how format/1 got a
  # map and FunctionClause-crashed every call).
  def format(other), do: "unknown (#{inspect(other)})"
end
