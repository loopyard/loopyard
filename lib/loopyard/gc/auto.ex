defmodule Loopyard.GC.Auto do
  @moduledoc """
  The automatic tier of Docker cleanup: on a timer, and at once when the disk
  monitor reports pressure, remove what `Loopyard.GC.select/2` picks — only
  what is provably Loopyard's own AND provably unused (test-suite volumes,
  finished sign-in / copy throwaways, superseded base-image tags). Nothing a
  human would want asked about; that is `GC.Review`, on `/system/docker`.

  ## Seen twice before it goes

  A candidate is removed only when an EARLIER look, at least
  `:gc_auto_min_age_ms` ago (10 min), already saw it as a candidate. Docker's
  listing has no age for a volume, and "dangling right now" is also what a
  test run's volume looks like in the moment between `volume create` and the
  container that mounts it. Two looks apart is the age check, made of data we
  have. Removal is never forced, so anything that came into use between the
  look and the `rm` is refused by Docker and simply stays.

  ## When it runs

    * a first look shortly after boot, then every `:gc_auto_interval_ms`
      (1 hour; `nil` disables it, as in tests);
    * `sweep_now/0`, which `Docker.DiskMonitor` calls when the disk turns
      degraded or down — and which re-looks after the minimum age when what it
      found was too new to take yet.

  The work runs in a Task (a listing of thousands of volumes takes seconds);
  one at a time. The last result is kept for `/system/docker`.
  """
  use GenServer
  require Logger

  alias Loopyard.GC

  @default_interval_ms :timer.hours(1)
  @default_min_age_ms :timer.minutes(10)
  @first_look_ms 90_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc "Look now; remove what an earlier look already saw. Cast; a no-op if not running."
  def sweep_now do
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, :sweep)
    :ok
  end

  @doc """
  `%{last: nil | %{at, removed, freed_bytes, failed}, watching: n}` — the last
  sweep that removed or tried to remove something, and how many candidates
  are waiting out the minimum age.
  """
  def status do
    GenServer.call(__MODULE__, :status, 500)
  catch
    :exit, _ -> %{last: nil, watching: 0}
  end

  @doc "Block until queued messages are applied and any sweep in flight has landed (tests)."
  def sync, do: GenServer.call(__MODULE__, :sync, 30_000)

  @impl true
  def init(_opts) do
    if interval(), do: Process.send_after(self(), :tick, @first_look_ms)
    {:ok, %{seen: %{}, last: nil, sweeping: nil, waiters: [], relook: nil}}
  end

  @impl true
  def handle_call(:status, _from, state),
    do: {:reply, %{last: state.last, watching: map_size(state.seen)}, state}

  def handle_call(:sync, from, %{sweeping: {_ref, _urgent?}} = state),
    do: {:noreply, %{state | waiters: [from | state.waiters]}}

  def handle_call(:sync, _from, state), do: {:reply, :ok, state}

  def handle_call(msg, _from, state) do
    Logger.warning("[GC.Auto] unhandled call: #{inspect(msg, limit: 50)}")
    {:reply, {:error, :unknown_call}, state}
  end

  @impl true
  def handle_cast(:sweep, state), do: {:noreply, start_sweep(state, true)}

  def handle_cast(msg, state) do
    Logger.warning("[GC.Auto] unhandled cast: #{inspect(msg, limit: 50)}")
    {:noreply, state}
  end

  @impl true
  def handle_info(:tick, state) do
    if ms = interval(), do: Process.send_after(self(), :tick, ms)
    {:noreply, start_sweep(state, false)}
  end

  def handle_info(:relook, state), do: {:noreply, start_sweep(%{state | relook: nil}, false)}

  def handle_info({ref, result}, %{sweeping: {ref, urgent?}} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | sweeping: nil} |> apply_sweep(result, urgent?) |> release_waiters()}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %{sweeping: {ref, _}} = state) do
    Logger.warning("[GC.Auto] sweep task died: #{inspect(reason, limit: 20)}")
    {:noreply, release_waiters(%{state | sweeping: nil})}
  end

  def handle_info(msg, state) do
    Logger.debug("[GC.Auto] ignored info: #{inspect(msg, limit: 50)}")
    {:noreply, state}
  end

  # ── internals ─────────────────────────────────────────────────────────

  defp interval, do: Application.get_env(:loopyard, :gc_auto_interval_ms, @default_interval_ms)
  defp min_age, do: Application.get_env(:loopyard, :gc_auto_min_age_ms, @default_min_age_ms)

  defp start_sweep(%{sweeping: {_ref, _}} = state, _urgent?), do: state

  defp start_sweep(state, urgent?) do
    seen = state.seen
    now = now_ms()
    age = min_age()
    survey = Application.get_env(:loopyard, :gc_auto_survey_fun, &survey/0)
    remove = Application.get_env(:loopyard, :gc_auto_remove_fun, &GC.Runner.remove/1)

    %Task{ref: ref} = Task.async(fn -> safe(fn -> sweep(survey, remove, seen, now, age) end) end)
    %{state | sweeping: {ref, urgent?}}
  end

  # `{:ok, candidates, removal}`: every current candidate, and what removing
  # the ripe ones did (nil when none was ripe).
  defp sweep(survey, remove, seen, now, age) do
    case survey.() do
      {:ok, candidates} ->
        ripe = Enum.filter(candidates, &ripe?(seen, key(&1), now, age))
        {:ok, candidates, if(ripe == [], do: nil, else: remove.(ripe))}

      other ->
        other
    end
  end

  defp ripe?(seen, key, now, age) do
    case Map.fetch(seen, key) do
      {:ok, first_seen} -> now - first_seen >= age
      :error -> false
    end
  end

  defp survey do
    cond do
      not Loopyard.Docker.daemon_available?() ->
        :skipped

      not Loopyard.DockerDaemon.up?() ->
        :skipped

      true ->
        with {:ok, listings} <- GC.Runner.listings(), do: GC.select(listings, GC.Runner.opts())
    end
  end

  defp apply_sweep(state, {:ok, candidates, removal}, urgent?) do
    now = now_ms()
    gone = MapSet.new((removal && removal.removed) || [], &key/1)

    # Keep the first-seen time of what is still a candidate; forget the rest.
    seen =
      for c <- candidates, k = key(c), not MapSet.member?(gone, k), into: %{} do
        {k, Map.get(state.seen, k, now)}
      end

    state = %{state | seen: seen}
    state = if removal, do: record(state, removal), else: state
    # Pressure, and something too new to take yet: come back for it.
    if urgent? and seen != %{}, do: schedule_relook(state), else: state
  end

  defp apply_sweep(state, :skipped, _urgent?), do: state

  defp apply_sweep(state, other, _urgent?) do
    Loopyard.EventLog.warning("docker", "automatic cleanup failed: #{inspect(other, limit: 10)}")
    state
  end

  defp record(state, %{removed: removed, failed: failed}) do
    freed = GC.total(removed)

    if removed != [] do
      Loopyard.EventLog.info(
        "docker",
        "automatic cleanup removed #{length(removed)} of Loopyard's own leftovers " <>
          "(#{Loopyard.Docker.Disk.human_bytes(freed)})"
      )

      :telemetry.execute(
        [:loopyard, :docker, :gc],
        %{removed: length(removed), freed_bytes: freed, failed: length(failed)},
        %{}
      )

      # The disk row should say so now, not at its next 5-minute probe.
      if Process.whereis(Loopyard.Docker.DiskMonitor), do: Loopyard.Docker.DiskMonitor.probe_now()
    end

    %{
      state
      | last: %{
          at: DateTime.utc_now(),
          removed: length(removed),
          freed_bytes: freed,
          failed: length(failed)
        }
    }
  end

  defp schedule_relook(%{relook: ref} = state) when is_reference(ref), do: state

  defp schedule_relook(state),
    do: %{state | relook: Process.send_after(self(), :relook, min_age() + 1_000)}

  defp release_waiters(state) do
    Enum.each(state.waiters, &GenServer.reply(&1, :ok))
    %{state | waiters: []}
  end

  defp key(%{kind: kind, name: name}), do: {kind, name}
  defp now_ms, do: System.monotonic_time(:millisecond)

  defp safe(fun) do
    fun.()
  rescue
    e -> {:error, Exception.message(e)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
