defmodule Loopyard.Docker.DiskMonitor do
  @moduledoc """
  Watches free space in the Docker VM on a slow tick (issue #117) and is the
  ONE writer of the disk row on `/system` and the disk item in the inbox.

  * **Probe** — every `:docker_disk_probe_ms` (default 5 min; nil disables
    the timer, as in test). `df -P /` through an already-running Loopyard
    container (from `Docker.Observer`'s cache — no `docker ps`), else a
    `--rm --pull never` run of the base image, which is always present where
    agents run. Never pulls. Skipped while the daemon gate is closed or the
    daemon is down (`Loopyard.DockerDaemon` owns that story). The probe runs in
    a Task, so `status/0` never waits on Docker.
  * **Verdict** — `Loopyard.Docker.Disk.status/2`: healthy, degraded below
    `:docker_disk_degraded_free_bytes`, down below
    `:docker_disk_down_free_bytes` or once a write failed with ENOSPC.
  * **Inbox** — on a LEVEL change only: degraded/down raises (or updates) the
    one `Disk.alert_id/0` item; back to healthy settles it. Nothing in any
    agent's chat — the inbox is where a human-only action lives.
  * **`report_full/1`** — anything that sees ENOSPC (the ACP connection's
    dying words) reports it, so the item appears now, not at the next tick.

  Test seams: `:docker_disk_probe_fun` (a 0-arity fun returning
  `{:ok, reading} | :full | {:error, term}`), `probe_now/0`, `sync/0`.
  """
  use GenServer
  require Logger

  alias Loopyard.Docker
  alias Loopyard.Docker.Disk
  alias Loopyard.Notifications

  @default_probe_ms 5 * 60 * 1000
  @first_probe_ms 30_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The current health status (never blocks on Docker)."
  @spec status() :: :healthy | {:degraded, String.t()} | {:down, String.t()}
  def status, do: GenServer.call(__MODULE__, :status, 500)

  @doc "The last observation: `%{free_bytes, total_bytes}`, `:full`, or nil."
  def observation, do: GenServer.call(__MODULE__, :observation, 500)

  @doc "Something saw a write fail with ENOSPC. Cast; a no-op if not running."
  def report_full(detail \\ nil) do
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, {:observed, :full, detail})
    :ok
  end

  @doc "Probe now (tests, tools)."
  def probe_now, do: send(__MODULE__, :probe)

  @doc "Block until queued messages are applied (tests)."
  def sync, do: GenServer.call(__MODULE__, :sync)

  @impl true
  def init(_opts) do
    if probe_interval(), do: Process.send_after(self(), :probe, @first_probe_ms)
    {:ok, %{observation: nil, level: nil, probing: nil, at: nil}}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, Disk.status(state.observation), state}
  def handle_call(:observation, _from, state), do: {:reply, state.observation, state}
  def handle_call(:sync, _from, state), do: {:reply, :ok, state}

  def handle_call(msg, _from, state) do
    Logger.warning("[DiskMonitor] unhandled call: #{inspect(msg, limit: 50)}")
    {:reply, {:error, :unknown_call}, state}
  end

  @impl true
  def handle_cast({:observed, obs, _detail}, state), do: {:noreply, observe(state, obs)}

  def handle_cast(msg, state) do
    Logger.warning("[DiskMonitor] unhandled cast: #{inspect(msg, limit: 50)}")
    {:noreply, state}
  end

  @impl true
  def handle_info(:probe, state) do
    if ms = probe_interval(), do: Process.send_after(self(), :probe, ms)
    {:noreply, start_probe(state)}
  end

  def handle_info({ref, result}, %{probing: ref} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, apply_probe(%{state | probing: nil}, result)}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %{probing: ref} = state) do
    Logger.warning("[DiskMonitor] probe task died: #{inspect(reason, limit: 20)}")
    {:noreply, %{state | probing: nil}}
  end

  def handle_info(msg, state) do
    Logger.debug("[DiskMonitor] ignored info: #{inspect(msg, limit: 50)}")
    {:noreply, state}
  end

  # ── internals ─────────────────────────────────────────────────────────

  defp probe_interval,
    do: Application.get_env(:loopyard, :docker_disk_probe_ms, @default_probe_ms)

  # One probe in flight at a time; a stuck one (15s docker timeout) is not
  # doubled up by the next tick.
  defp start_probe(%{probing: ref} = state) when is_reference(ref), do: state

  defp start_probe(state) do
    fun = Application.get_env(:loopyard, :docker_disk_probe_fun, &probe/0)
    %Task{ref: ref} = Task.async(fn -> safe(fun) end)
    %{state | probing: ref}
  end

  defp safe(fun) do
    fun.()
  rescue
    e -> {:error, Exception.message(e)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp apply_probe(state, {:ok, %{free_bytes: _, total_bytes: _} = reading}),
    do: observe(state, reading)

  defp apply_probe(state, :full), do: observe(state, :full)
  defp apply_probe(state, :skipped), do: state

  # A probe that failed for some OTHER reason says nothing about the disk:
  # keep the last verdict rather than flip the inbox on a transient.
  defp apply_probe(state, other) do
    Loopyard.EventLog.warning("docker", "disk probe failed: #{inspect(other, limit: 10)}")
    state
  end

  defp observe(state, obs) do
    level = obs |> Disk.status() |> Disk.level()
    state = %{state | observation: obs, at: DateTime.utc_now()}

    if level == state.level do
      state
    else
      transition(level, Disk.status(obs))
      %{state | level: level}
    end
  end

  defp transition(:healthy, _status) do
    case Notifications.get(Disk.alert_id()) do
      %{status: :open} ->
        Loopyard.EventLog.info("docker", "disk space recovered")
        Notifications.settle(Disk.alert_id(), :recovered)

      _ ->
        :ok
    end
  end

  defp transition(level, status) do
    Loopyard.EventLog.warning("docker", "disk #{level}: #{elem(status, 1)}")
    Notifications.upsert(Disk.alert_item(level, status))
  end

  @doc """
  The real probe: `df -P /` inside a running Loopyard container, else a
  throwaway `--rm` container of the base image (`--pull never`). Returns
  `{:ok, reading} | :full | :skipped | {:error, term}`.
  """
  def probe do
    cond do
      not Docker.daemon_available?() -> :skipped
      not Loopyard.DockerDaemon.up?() -> :skipped
      true -> run_df()
    end
  end

  defp run_df do
    result =
      case running_container() do
        name when is_binary(name) ->
          Docker.docker(["exec", name, "df", "-Pk", "/"], timeout: 15_000, retry: false)

        nil ->
          Docker.docker(
            ~w(run --rm --network none --pull never) ++
              [Loopyard.Workspace.WorkContainer.image(), "df", "-Pk", "/"],
            timeout: 30_000,
            retry: false
          )
      end

    case result do
      {:ok, out} ->
        Disk.parse_df(out)

      {:error, out} ->
        if Disk.full_error?(out), do: :full, else: {:error, String.slice(to_string(out), 0, 300)}
    end
  end

  defp running_container do
    Docker.Observer.containers()
    |> Enum.filter(& &1[:running])
    |> Enum.map(& &1.name)
    |> Enum.find(&String.starts_with?(&1, Docker.prefix()))
  rescue
    _ -> nil
  end
end
