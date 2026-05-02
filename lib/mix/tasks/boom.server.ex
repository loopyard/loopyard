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
    # Cookie always lives at ~/.boomlooper/cookie so boom.rpc can find it
    cookie = ensure_cookie()

    case Node.start(:boom, :shortnames) do
      {:ok, _} ->
        Node.set_cookie(cookie)

      {:error, reason} ->
        Mix.shell().info(
          "Warning: could not start distributed node (#{inspect(reason)}). Remote shell access disabled."
        )
    end

    # Start the Phoenix endpoint
    Application.put_env(:phoenix, :serve_endpoints, true)
    Mix.Tasks.Run.run(["--no-halt"])
  end

  defp ensure_cookie do
    # Always use ~/.boomlooper for the cookie — never BOOMLOOPER_HOME.
    # BOOMLOOPER_HOME is for workspace data. Using it for cookies causes
    # mismatches when direnv caches a stale value.
    home = Path.join(System.user_home!(), ".boomlooper")
    path = Path.join(home, "cookie")

    cookie =
      if File.exists?(path) do
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
