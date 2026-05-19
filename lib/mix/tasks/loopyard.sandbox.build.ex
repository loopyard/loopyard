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
    Mix.shell().info("Building #{image}...")

    case Loopyard.AgentSandbox.build_image() do
      :ok ->
        Mix.shell().info("\n✓ Built #{image}")

      {:error, :docker_not_installed} ->
        Mix.raise("docker is not installed — install Docker first.")

      {:error, output} ->
        Mix.raise("docker build failed:\n#{output}")
    end
  end
end
