defmodule Loopyard.Tools.Container.InspectEnv do
  use Loopyard.Tool,
    name: "inspect_env",
    description:
      "Inspect the container environment: installed languages, databases, tools, running processes, listening ports",
    busy_words: ["checking the environment", "env snooping"],
    params: [
      agent_id: {:string, required: true}
    ]

  alias Loopyard.Docker
  alias Loopyard.Tools.Container.Helpers

  def execute(%{agent_id: agent_id}, _assigns) do
    case Helpers.resolve_container(agent_id) do
      {:ok, container} ->
        checks = [
          {"Running processes", "ps aux --no-headers 2>/dev/null || ps 2>/dev/null"},
          {"Listening ports",
           "ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null || echo '[ss/netstat not available]'"},
          {"Installed languages",
           "for cmd in node python3 ruby go java elixir; do which $cmd 2>/dev/null && $cmd --version 2>&1 | head -1; done"},
          {"Installed databases",
           "for cmd in psql mysql redis-cli mongosh sqlite3; do which $cmd 2>/dev/null && echo \"  $cmd available\"; done"},
          {"Installed tools",
           "for cmd in git curl wget make gcc npm yarn pip cargo mix bundle; do which $cmd 2>/dev/null; done"},
          {"Disk usage", "df -h /workspace 2>/dev/null | tail -1"}
        ]

        results =
          Enum.map(checks, fn {label, cmd} ->
            output =
              # login: true so env checks reflect identity env sourced from
              # ~/.profile (tokens live in the home volume, not `docker run -e`).
              case Docker.exec_in(container, cmd, login: true) do
                {:ok, out} -> String.trim(out)
                {:error, _} -> "[error]"
              end

            "## #{label}\n#{output}"
          end)

        {:ok, Helpers.truncate_for_agent(Enum.join(results, "\n\n"))}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
