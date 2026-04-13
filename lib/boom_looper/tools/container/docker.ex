defmodule BoomLooper.Tools.Container.Docker do
  use BoomLooper.Tool,
    name: "docker",
    description: "Run any Docker CLI command. Use for inspecting containers, volumes, images, networks, etc.",
    params: [
      agent_id: {:string, required: true},
      command: {:string, required: true, description: "Docker command (e.g. 'ps -a', 'volume ls', 'inspect mycontainer', 'images')"},
      timeout: {:integer, description: "Max seconds to run (default: 30)"}
    ]

  alias BoomLooper.Tools.Container.Helpers

  def execute(%{agent_id: _agent_id, command: command} = params, _assigns) do
    timeout_seconds = Map.get(params, :timeout, 30)
    args = String.split(command, ~r/\s+/, trim: true)

    case BoomLooper.Docker.docker(args, timeout: timeout_seconds * 1_000) do
      {:ok, output} -> {:ok, Helpers.truncate_for_agent(output)}
      {:error, output} -> {:error, Helpers.truncate_for_agent(output)}
    end
  end
end
