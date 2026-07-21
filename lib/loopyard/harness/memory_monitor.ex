defmodule Loopyard.Harness.MemoryMonitor do
  @moduledoc """
  Proactive harness memory management (Layer 2 of containment).

  The Claude Code harness (claude-code-acp + the `claude` CLI) is a known
  resource hog that leaks — left alone it can grow into tens of GB. Two layers
  keep that from hurting the user's machine:

    * **Layer 1 — hard cap (WorkContainer).** The work container has a
      `--memory` ceiling, so a bloated harness is OOM-killed INSIDE the
      container and never touches the host. That's the guarantee.
    * **Layer 2 — this monitor.** The hard cap is a safety net that fires
      *mid-turn* and is disruptive. This sweep reclaims bloat GRACEFULLY: it
      periodically reads each work container's memory and, when an **idle**
      agent's container has crossed a soft threshold (well under the hard cap),
      cleanly restarts that agent's harness session — reclaiming the leak
      between turns, before the hard cap ever has to fire.

  Only IDLE agents are restarted, so an active turn is never interrupted; a
  bloat that happens mid-turn is left for the hard cap (rare, recoverable). One
  `docker stats` sample per sweep covers the whole fleet.

  Config:

    * `:harness_memory_monitor_enabled?` (default `true`; `false` in test)
    * `:harness_memory_soft_limit_bytes` (default 4 GiB)
    * `:harness_memory_sweep_ms` (default 60_000)
  """
  use GenServer

  require Logger

  alias Loopyard.Workspace.WorkContainer

  @default_soft_limit 4 * 1024 * 1024 * 1024
  @default_sweep_ms 60_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    if enabled?() do
      schedule()
      {:ok, %{}}
    else
      :ignore
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    schedule()
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.warning("[Harness.MemoryMonitor] unhandled: #{inspect(msg, limit: 120)}")

    :telemetry.execute([:loopyard, :actor, :unknown_message], %{count: 1}, %{
      actor: __MODULE__,
      msg: inspect(msg, limit: 120)
    })

    {:noreply, state}
  end

  # --- sweep ---

  @doc """
  One sweep: read container memory once, restart every IDLE agent whose work
  container is over the soft limit. Public for a manual `mix loopyard.rpc` poke.
  """
  def sweep do
    usage = container_memory_bytes()
    soft = soft_limit_bytes()

    for summary <- live_idle_agents(),
        ws = summary[:workspace_id],
        is_binary(ws),
        bytes = usage[WorkContainer.container_name(ws)],
        is_integer(bytes) and bytes > soft do
      reclaim(summary, bytes, soft)
    end

    :ok
  rescue
    e ->
      Logger.warning("[Harness.MemoryMonitor] sweep error: #{Exception.message(e)}")
      :ok
  end

  defp reclaim(summary, bytes, soft) do
    id = summary[:id]

    Loopyard.EventLog.warning(
      "harness:memory",
      "Harness for agent #{String.slice(to_string(id), 0, 8)} bloated to #{gb(bytes)} " <>
        "(soft limit #{gb(soft)}) while idle — proactively restarting to reclaim before the hard cap."
    )

    :telemetry.execute(
      [:loopyard, :harness, :memory_reclaim],
      %{bytes: bytes},
      %{agent_id: id}
    )

    case Registry.lookup(Loopyard.ChatAgentRegistry, id) do
      # :memory_reclaim → no "crashed" line in the chat; this is maintenance
      # on a healthy idle agent (the EventLog warning above carries the why).
      [{pid, _}] -> GenServer.cast(pid, {:restart_session, :memory_reclaim})
      [] -> :ok
    end
  end

  # Only agents that are alive AND idle — never interrupt an active turn.
  defp live_idle_agents do
    Loopyard.ChatAgent.list_agent_summaries()
    |> Enum.filter(fn a -> a[:status] == :idle end)
  rescue
    _ -> []
  end

  # `docker stats --no-stream` → %{container_name => used_bytes}. One sample for
  # the whole fleet; parses the "used / limit" MemUsage column's used side.
  defp container_memory_bytes do
    case Loopyard.Docker.docker([
           "stats",
           "--no-stream",
           "--format",
           "{{.Name}}\t{{.MemUsage}}"
         ]) do
      {:ok, out} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.reduce(%{}, fn line, acc ->
          case String.split(line, "\t", parts: 2) do
            [name, mem] ->
              case parse_used_bytes(mem) do
                nil -> acc
                bytes -> Map.put(acc, String.trim(name), bytes)
              end

            _ ->
              acc
          end
        end)

      {:error, _} ->
        %{}
    end
  end

  # "1.234GiB / 8GiB" → bytes of the USED side. Handles B/KiB/MiB/GiB (and the
  # SI kB/MB/GB Docker sometimes prints). Public (@doc false) for unit tests.
  @doc false
  def parse_used_bytes(mem) do
    used = mem |> String.split("/", parts: 2) |> List.first() |> String.trim()

    case Regex.run(~r/^([\d.]+)\s*([A-Za-z]+)$/, used) do
      [_, num, unit] ->
        case Float.parse(num) do
          {value, _} -> round(value * unit_multiplier(unit))
          :error -> nil
        end

      _ ->
        nil
    end
  end

  @doc false
  def unit_multiplier(unit) do
    case String.downcase(unit) do
      "b" -> 1
      "kib" -> 1024
      "mib" -> 1024 * 1024
      "gib" -> 1024 * 1024 * 1024
      "kb" -> 1000
      "mb" -> 1000 * 1000
      "gb" -> 1000 * 1000 * 1000
      _ -> 0
    end
  end

  defp gb(bytes), do: "#{Float.round(bytes / (1024 * 1024 * 1024), 2)}GB"

  # --- config ---

  defp enabled?, do: Application.get_env(:loopyard, :harness_memory_monitor_enabled?, true)

  defp soft_limit_bytes,
    do: Application.get_env(:loopyard, :harness_memory_soft_limit_bytes, @default_soft_limit)

  defp schedule do
    ms = Application.get_env(:loopyard, :harness_memory_sweep_ms, @default_sweep_ms)
    Process.send_after(self(), :sweep, ms)
  end
end
