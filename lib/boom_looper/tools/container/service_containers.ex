defmodule BoomLooper.Tools.Container.ServiceContainers do
  @moduledoc false

  alias BoomLooper.Docker

  def __tool_name__, do: "service_containers"

  def __description__,
    do:
      "List all containers for this workspace. Call ONCE after rebuild completes. Do NOT poll — if containers aren't up, read logs instead."

  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "agent_id" => %{"type" => "string"}
      },
      "required" => ["agent_id"]
    }
  end

  def execute(%{agent_id: agent_id}, _assigns) do
    case BoomLooper.ChatAgent.get_state(agent_id) do
      %{workspace_id: workspace_id} when is_binary(workspace_id) ->
        prefix = "bl-#{workspace_id}"

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
