defmodule Loopyard.Tools.Workstation.Console do
  use Loopyard.Tool,
    name: "console",
    description:
      "Run a shell command in the live workstation container. Use this to TEST something before baking it into the Dockerfile — e.g. `apt-get install -y postgresql-client` to confirm the package name, then add that line via write_dockerfile and rebuild_image. Note: anything you install here is ephemeral (gone on the next image rebuild / container recreate) — promote keepers to the Dockerfile. Do NOT run logins here (those are the user's to do in their console).",
    busy_words: ["running in the console", "testing a command"],
    params: [
      agent_id: {:string, required: true},
      command: {:string, required: true},
      timeout: {:integer, description: "Max seconds to run (default: 120)"}
    ]

  alias Loopyard.Docker
  alias Loopyard.Tools.Container.Helpers
  alias Loopyard.Workstation.Container

  def execute(%{agent_id: _id, command: command} = params, _assigns) do
    timeout = Map.get(params, :timeout, 120)

    with :ok <- Helpers.validate_string(command, "command", 10_000),
         :ok <- Helpers.validate_timeout(timeout),
         {:ok, name} <- Container.ensure_up() do
      case Docker.exec_in(name, command, timeout: timeout * 1_000) do
        {:ok, output} -> {:ok, Helpers.truncate_for_agent(output)}
        {:error, output} when is_binary(output) -> {:error, Helpers.truncate_for_agent(output)}
        {:error, reason} -> {:error, "Command failed: #{inspect(reason)}"}
      end
    end
  end
end
