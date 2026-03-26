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
    # Use a BOOMLOOPER_HOME-scoped cookie so tools can connect without ~/.erlang.cookie
    cookie = ensure_cookie()
    Node.start(:boom, :shortnames)
    Node.set_cookie(cookie)

    # Start the Phoenix endpoint
    Application.put_env(:phoenix, :serve_endpoints, true)
    Mix.Tasks.Run.run(["--no-halt"])
  end

  defp ensure_cookie do
    home = System.get_env("BOOMLOOPER_HOME") || Path.join(System.user_home!(), ".boomlooper")
    path = Path.join(home, "cookie")

    cookie = if File.exists?(path) do
      path |> File.read!() |> String.trim()
    else
      File.mkdir_p!(home)
      c = :crypto.strong_rand_bytes(16) |> Base.encode64(padding: false)
      File.write!(path, c)
      c
    end

    String.to_atom(cookie)
  end
end
