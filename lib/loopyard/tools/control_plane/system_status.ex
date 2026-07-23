defmodule Loopyard.Tools.ControlPlane.SystemStatus do
  @moduledoc """
  A read-only snapshot of the machine + Loopyard itself for the operator: host
  memory, Loopyard's subsystem `Health`, the BEAM's own footprint, and live agent
  counts. This is the ONLY window the operator gets onto the host — deliberately a
  curated read, NEVER a host shell (the operator's `exec` stays inside its
  container; see docs/SECURITY.md). Pure introspection, no side effects.
  """
  use Loopyard.Tool,
    name: "system_status",
    description:
      "A read-only snapshot of the machine + Loopyard: host memory, Loopyard's " <>
        "subsystem health (Docker, PubSub, reconciler, …), the BEAM's memory, and " <>
        "live agent counts. Answers 'how's the system / how much memory / is " <>
        "anything unhealthy'. Read-only — it never runs host commands.",
    busy_words: ["checking the system"],
    params: [
      agent_id: {:string, required: true}
    ]

  def execute(_params, _assigns) do
    {:ok, Enum.join([memory_line(), health_block(), agents_line()], "\n")}
  rescue
    e -> {:error, "Couldn't read system status: #{inspect(e)}"}
  end

  defp memory_line do
    beam = :erlang.memory(:total)

    case host_memory() do
      {total, free} ->
        "Host memory: #{gb(free)} free of #{gb(total)}  ·  Loopyard (BEAM): #{mb(beam)}"

      nil ->
        "Loopyard (BEAM) memory: #{mb(beam)}  ·  host memory: unavailable"
    end
  end

  # `:memsup` (os_mon) reports host RAM cross-platform when available; guarded so a
  # missing/undstarted os_mon degrades to "unavailable" instead of raising.
  defp host_memory do
    data = :memsup.get_system_memory_data()
    total = data[:total_memory] || data[:system_total_memory]
    free = data[:available_memory] || data[:free_memory]
    if is_integer(total) and is_integer(free), do: {total, free}, else: nil
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp health_block do
    overall = Loopyard.Health.format(Loopyard.Health.overall())

    comps =
      Loopyard.Health.components()
      |> Enum.map_join("\n", fn c ->
        "  - #{c}: #{Loopyard.Health.format(Loopyard.Health.component(c))}"
      end)

    "Health: #{overall}\n#{comps}"
  end

  defp agents_line do
    summaries = Loopyard.ChatAgent.list_agent_summaries()

    breakdown =
      summaries
      |> Enum.frequencies_by(& &1[:status])
      |> Enum.map_join(", ", fn {s, n} -> "#{s}: #{n}" end)

    "Agents: #{length(summaries)}" <> if(breakdown == "", do: "", else: " (#{breakdown})")
  end

  defp gb(bytes), do: "#{Float.round(bytes / 1_073_741_824, 1)}G"
  defp mb(bytes), do: "#{trunc(bytes / 1_048_576)}M"
end
