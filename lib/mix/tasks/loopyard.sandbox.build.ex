defmodule Mix.Tasks.Loopyard.Sandbox.Build do
  @moduledoc """
  Build the Loopyard agent sandbox Docker image.

  ## Usage

      mix loopyard.sandbox.build

  Builds `loopyard/agent-sandbox:<version>` from
  `priv/agent-sandbox/Dockerfile`. The version comes from
  `Loopyard.AgentSandbox.image_name/0` — bump it in code when the
  Dockerfile changes.

  Idempotent — re-runs reuse Docker's build cache.
  """

  use Mix.Task

  @shortdoc "Build the loopyard/agent-sandbox image"

  @impl Mix.Task
  def run(_args) do
    Application.ensure_all_started(:loopyard)

    image = Loopyard.AgentSandbox.image_name()
    dockerfile_dir = Application.app_dir(:loopyard, ["priv", "agent-sandbox"])

    Mix.shell().info("Building #{image} from #{dockerfile_dir}...")

    case System.cmd("docker", ["build", "-t", image, dockerfile_dir],
           stderr_to_stdout: true,
           into: IO.stream(:stdio, :line)
         ) do
      {_, 0} ->
        Mix.shell().info("\n✓ Built #{image}")

      {_, status} ->
        Mix.raise("docker build failed with exit status #{status}")
    end
  end
end
