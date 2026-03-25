defmodule Mix.Tasks.Boom.Server do
  @moduledoc """
  Starts BoomLooper with IEx console and node name for remote access.

  ## Usage

      mix boom.server

  Then connect remotely:

      iex --sname claude --remsh boom@$(hostname -s)
  """

  use Mix.Task

  @shortdoc "Start BoomLooper with IEx console"

  @impl Mix.Task
  def run(_args) do
    # Start as distributed node
    Node.start(:boom, :shortnames)

    # Start the Phoenix endpoint
    Application.put_env(:phoenix, :serve_endpoints, true)
    Mix.Tasks.Run.run(["--no-halt"])
  end
end
