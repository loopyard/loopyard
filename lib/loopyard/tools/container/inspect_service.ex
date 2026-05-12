defmodule Loopyard.Tools.Container.InspectService do
  use Loopyard.Tool,
    name: "inspect_service",
    description:
      "Get a complete snapshot of one service in ONE call: container state, exit code, host/container port mapping, last 50 log lines, and an extracted error summary. PREFER THIS over fanning out to `docker_compose ps` + `logs` + `ports` + `docker port` separately.",
    busy_words: ["inspecting", "diagnosing", "checking vitals"],
    params: [
      agent_id: {:string, required: true},
      name:
        {:string,
         required: true,
         description: "Service name from docker-compose.yml (e.g. 'dev', 'postgres', 'redis')"}
    ]

  alias Loopyard.Docker
  alias Loopyard.Tools.Container.Helpers

  def execute(%{agent_id: agent_id, name: name}, _assigns) do
    with {:ok, workspace_id} <- Helpers.agent_workspace_id(agent_id) do
      container = "#{Loopyard.Compose.project_name(workspace_id)}-#{name}-1"

      case Docker.container_state(container) do
        nil ->
          {:ok, format_missing_service(name, container)}

        state ->
          ports = Docker.container_ports(container)

          logs =
            case Docker.container_logs(container, tail: 50) do
              {:ok, output} -> output
              _ -> "(could not fetch logs)"
            end

          {:ok, format_service_inspection(name, container, state, ports, logs)}
      end
    end
  end

  defp format_missing_service(name, container) do
    """
    Service `#{name}` (#{container}): NOT FOUND.

    The container doesn't exist. Check `service_containers` to see what's
    actually running, or `docker_compose("ps")` to see compose services.
    """
  end

  defp format_service_inspection(name, container, state, ports, logs) do
    port_lines =
      if map_size(ports) == 0 do
        "  (no published host ports)"
      else
        ports
        |> Enum.map(fn {cport, hport} -> "  #{cport} → host:#{hport}" end)
        |> Enum.join("\n")
      end

    error_lines = extract_error_lines(logs)

    error_section =
      case error_lines do
        [] -> ""
        lines -> "\nDetected errors:\n#{Enum.map_join(lines, "\n", &("  " <> &1))}\n"
      end

    """
    Service: #{name}  (#{container})
    State:   #{state.status}#{exit_summary(state)}
    Published ports:
    #{port_lines}
    #{error_section}
    Last 50 log lines:
    #{logs}
    """
  end

  defp exit_summary(%{status: "running"}), do: ""
  defp exit_summary(%{exit_code: 0}), do: " (exit 0 — clean)"
  defp exit_summary(%{exit_code: 137, oom_killed: true}), do: " (exit 137 — OOM killed)"
  defp exit_summary(%{exit_code: 137}), do: " (exit 137 — SIGKILL)"
  defp exit_summary(%{exit_code: 143}), do: " (exit 143 — SIGTERM)"

  defp exit_summary(%{exit_code: code, error: error}) when is_binary(error) and error != "" do
    " (exit #{code} — #{error})"
  end

  defp exit_summary(%{exit_code: code}), do: " (exit #{code})"
  defp exit_summary(_), do: ""

  defp extract_error_lines(logs) when is_binary(logs) do
    logs
    |> String.split("\n")
    |> Enum.filter(fn line ->
      lower = String.downcase(line)

      String.contains?(lower, "error") or
        String.contains?(lower, "fatal") or
        String.contains?(lower, "exception") or
        String.contains?(lower, "panic") or
        String.contains?(lower, "traceback") or
        String.contains?(lower, "cannot") or
        String.contains?(lower, "refused") or
        String.contains?(lower, "denied")
    end)
    |> Enum.take(8)
  end

  defp extract_error_lines(_), do: []
end
