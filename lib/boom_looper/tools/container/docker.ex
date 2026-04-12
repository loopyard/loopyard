defmodule BoomLooper.Tools.Container.Docker do
  @moduledoc false

  def __tool_name__, do: "docker"

  def __description__,
    do: "Run any Docker CLI command. Use for inspecting containers, volumes, images, networks, etc."

  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "agent_id" => %{"type" => "string"},
        "command" => %{
          "type" => "string",
          "description" =>
            "Docker command (e.g. 'ps -a', 'volume ls', 'inspect mycontainer', 'images')"
        },
        "timeout" => %{
          "type" => "integer",
          "description" => "Max seconds to run (default: 30)"
        }
      },
      "required" => ["agent_id", "command"]
    }
  end

  def execute(%{agent_id: _agent_id, command: command} = params, _assigns) do
    timeout_seconds = Map.get(params, :timeout, 30)
    args = String.split(command, ~r/\s+/, trim: true)
    BoomLooper.Docker.docker(args, timeout: timeout_seconds * 1_000)
  end
end
