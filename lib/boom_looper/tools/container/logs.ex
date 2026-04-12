defmodule BoomLooper.Tools.Container.Logs do
  @moduledoc false

  alias BoomLooper.Docker
  alias BoomLooper.Tools.Container.Helpers

  def __tool_name__, do: "logs"

  def __description__,
    do:
      "View container logs (works on running AND stopped/crashed containers). Pass 'service' to see a specific service's logs (e.g. 'dev', 'postgres'). Use service_containers first to see what's available."

  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "agent_id" => %{"type" => "string"},
        "service" => %{
          "type" => "string",
          "description" => "Service name to get logs for (e.g. 'dev', 'postgres', 'redis')"
        },
        "lines" => %{"type" => "integer"}
      },
      "required" => ["agent_id"]
    }
  end

  def execute(%{agent_id: agent_id} = params, _assigns) do
    service = Map.get(params, :service)
    lines = Map.get(params, :lines, 200)

    if service do
      case Helpers.resolve_service_container(agent_id, service) do
        {:ok, container} -> Docker.container_logs(container, tail: lines)
        {:error, reason} -> {:error, reason}
      end
    else
      case Helpers.resolve_container(agent_id) do
        {:ok, container} -> Docker.container_logs(container, tail: lines)
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
