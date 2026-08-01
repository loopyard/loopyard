defmodule Loopyard.Tools.Container.ServiceContainers do
  use Loopyard.Tool,
    name: "service_containers",
    description:
      "List all containers for this workspace. Call ONCE after rebuild completes. Do NOT poll — if containers aren't up, read logs instead.",
    busy_words: ["listing containers", "taking inventory"],
    params: [
      agent_id: {:string, required: true}
    ]

  alias Loopyard.Docker

  def execute(%{agent_id: agent_id}, _assigns) do
    case Loopyard.ChatAgent.get_state(agent_id) do
      %{workspace_id: workspace_id} when is_binary(workspace_id) ->
        prefix = "#{Loopyard.Docker.prefix()}#{workspace_id}"

        case Docker.docker([
               "ps",
               "-a",
               "--filter",
               "name=#{prefix}",
               "--format",
               "{{.Names}}\t{{.Status}}\t{{.Ports}}"
             ]) do
          {:ok, ""} ->
            {:ok, "No containers found for this workspace."}

          {:ok, output} ->
            {:ok, output}

          {:error, reason} ->
            {:error, "Failed to list containers: #{reason}"}
        end

      _ ->
        {:error, "Agent #{agent_id} has no workspace"}
    end
  end
end
