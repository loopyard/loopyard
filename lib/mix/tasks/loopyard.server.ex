defmodule Mix.Tasks.Loopyard.Server do
  @moduledoc """
  Starts Loopyard with IEx console and node name for remote access.

  ## Usage

      mix loopyard.server

  Then connect remotely:

      iex --sname claude --remsh loopyard@$(hostname -s)
  """

  use Mix.Task

  @shortdoc "Start Loopyard with IEx console"

  @impl Mix.Task
  def run(_args) do
    # Cookie always lives at ~/.loopyard/cookie so loopyard.rpc can find it
    cookie = ensure_cookie()

    # Distribution needs EPMD listening first. When booted fresh from
    # `overmind start` (the `dev` command) nothing else has started it,
    # so `Node.start` fails with econnrefused/:nodistribution and remote
    # RPC is silently disabled. Start it ourselves — idempotent, returns
    # immediately if one is already running.
    ensure_epmd()

    # Loopback longname, NOT a hostname-derived shortname — macOS flips the
    # hostname (Mac ↔ Mac.localdomain ↔ macbook), which silently broke remote
    # access (`loopyard.rpc` could no longer find the node). 127.0.0.1 is stable.
    case Node.start(:"loopyard@127.0.0.1", :longnames) do
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

  # Boot EPMD if it isn't already up. `epmd -daemon` is idempotent (a no-op
  # when one is already listening) and detaches immediately, so this is safe
  # to call on every boot. Ships with Erlang/OTP, so it's always on PATH when
  # mix is. If it's somehow missing we don't fail the boot — Node.start below
  # will just warn and run non-distributed, same as before.
  defp ensure_epmd do
    case System.find_executable("epmd") do
      nil ->
        Mix.shell().info("Warning: epmd not found on PATH; distribution disabled.")

      epmd ->
        System.cmd(epmd, ["-daemon"])
    end
  rescue
    e ->
      Mix.shell().info("Warning: could not start epmd (#{Exception.message(e)}).")
  end

  defp ensure_cookie do
    # Always use ~/.loopyard for the cookie — never LOOPYARD_HOME.
    # LOOPYARD_HOME is for workspace data. Using it for cookies causes
    # mismatches when direnv caches a stale value.
    home = Path.join(System.user_home!(), ".loopyard")
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
