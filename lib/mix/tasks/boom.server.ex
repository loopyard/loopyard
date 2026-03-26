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

  @cookie_file ".erlang.cookie"

  @impl Mix.Task
  def run(_args) do
    # Use a project-local cookie so tools can connect without needing ~/.erlang.cookie
    cookie = ensure_cookie()
    Node.start(:boom, :shortnames)
    Node.set_cookie(cookie)

    # Start the Phoenix endpoint
    Application.put_env(:phoenix, :serve_endpoints, true)
    Mix.Tasks.Run.run(["--no-halt"])
  end

  defp ensure_cookie do
    path = Path.join(File.cwd!(), @cookie_file)

    cookie = if File.exists?(path) do
      path |> File.read!() |> String.trim()
    else
      c = :crypto.strong_rand_bytes(16) |> Base.encode64(padding: false)
      File.write!(path, c)
      c
    end

    String.to_atom(cookie)
  end
end
