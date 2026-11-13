defmodule Mix.Tasks.Loopyard.Service do
  @moduledoc """
  Run Loopyard as an always-on user service (macOS LaunchAgent, Linux
  systemd user unit) — it starts at login, restarts on crash and outlives
  the terminal it was installed from. See docs/HOSTING.md.

  ## Usage

      mix loopyard.service install [--checkout PATH] [--branch main] [--port 4000] [--bind IP]
      mix loopyard.service status
      mix loopyard.service restart
      mix loopyard.service update
      mix loopyard.service logs [--lines 100] [--follow]
      mix loopyard.service uninstall

  `install --checkout PATH` runs the service from a DEDICATED checkout,
  cloning this one there first when PATH does not exist yet. That is the
  recommended setup: the server runs with the dev code reloader, so a broken
  edit in the checkout it runs from freezes every page. `update` fast-forwards
  that checkout, compiles it and restarts the service — or, when the new code
  does not build, puts the checkout back and leaves the server running.

  `--bind` defaults to `LOOPYARD_BIND` (else loopback). `tailscale serve`
  and a named tunnel reach a loopback server; bind `0.0.0.0` only for
  direct LAN access.

  Install refuses while another server already holds the port (a
  `mix loopyard.server` in a terminal): stop it first.
  """

  use Mix.Task

  alias Loopyard.Hosting
  alias Loopyard.Hosting.{Addresses, Checkout}

  @shortdoc "Install / manage Loopyard as an always-on user service"

  @switches [
    checkout: :string,
    branch: :string,
    port: :integer,
    bind: :string,
    home: :string,
    lines: :integer,
    follow: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, argv, _} = OptionParser.parse(args, strict: @switches)

    if Hosting.platform() == :unsupported,
      do: Mix.raise("mix loopyard.service supports macOS (launchd) and Linux (systemd) only")

    case argv do
      ["install"] -> install(opts)
      ["uninstall"] -> uninstall(opts)
      ["status"] -> status(opts)
      ["restart"] -> restart(opts)
      ["update"] -> update(opts)
      ["logs"] -> logs(opts)
      _ -> Mix.raise("usage: mix loopyard.service install|uninstall|status|restart|update|logs")
    end
  end

  # ── commands ─────────────────────────────────────────────────────────────

  defp install(opts) do
    checkout = resolve_checkout(opts)

    config =
      [checkout: checkout, port: opts[:port], bind: opts[:bind], home: opts[:home]]
      |> Enum.reject(fn {_, v} -> is_nil(v) end)
      |> Hosting.config()

    case Hosting.install(config) do
      :ok ->
        info("Installed #{config.label} → #{Hosting.unit_path(config)}")
        info("It starts at login and restarts if it exits.\n")
        print_status(config)

      {:error, why} ->
        Mix.raise("install failed: #{why}")
    end
  end

  defp resolve_checkout(opts) do
    case opts[:checkout] do
      nil ->
        info("""
        Note: the service will run from THIS checkout (#{File.cwd!()}).
        An edit here that does not compile freezes every page of the running
        server. Prefer a dedicated one: mix loopyard.service install --checkout ~/loopyard-server
        """)

        File.cwd!()

      path ->
        path = Path.expand(path)

        if File.exists?(path) do
          path
        else
          branch = opts[:branch] || "main"
          info("Creating a dedicated checkout at #{path} (#{branch})…")

          case Checkout.create(File.cwd!(), path, branch, runner: &streaming_cmd/3) do
            :ok -> path
            {:error, why} -> Mix.raise("could not create #{path}: #{why}")
          end
        end
    end
  end

  defp uninstall(opts) do
    config = installed!(opts)
    :ok = Hosting.uninstall(config)
    info("Uninstalled #{config.label}. Logs kept in #{Hosting.log_dir(config)}.")
  end

  defp restart(opts) do
    config = installed!(opts)

    case Hosting.restart(config) do
      :ok -> info("Restarted #{config.label}.")
      {:error, why} -> Mix.raise("restart failed: #{why}")
    end
  end

  defp update(opts) do
    config = installed!(opts)
    info("Updating #{config.checkout}…")

    case Checkout.update(config.checkout, mix: config.mix, runner: &streaming_cmd/3) do
      {:ok, :up_to_date} ->
        info("Already up to date; the service was not restarted.")

      {:ok, {old, new}} ->
        :ok = ok!(Hosting.restart(config), "restart")
        info("Updated #{String.slice(old, 0, 8)} → #{String.slice(new, 0, 8)} and restarted.")

      {:error, why} ->
        Mix.raise("update failed: #{why}")
    end
  end

  defp status(opts) do
    case installed(opts) do
      nil ->
        info("Loopyard service: not installed (mix loopyard.service install).\n")
        config = Hosting.config(Enum.reject([home: opts[:home]], fn {_, v} -> is_nil(v) end))
        print_addresses(config, Hosting.port_open?(config.port))

      config ->
        print_status(config)
    end
  end

  defp logs(opts) do
    config = installed(opts) || Hosting.config([])

    files =
      [Hosting.service_log(config), Hosting.server_log(config)] |> Enum.filter(&File.exists?/1)

    cond do
      files == [] ->
        info("No logs yet in #{Hosting.log_dir(config)}.")

      opts[:follow] ->
        System.cmd("tail", ["-n", "#{opts[:lines] || 50}", "-F" | files], into: IO.stream())

      true ->
        for f <- files do
          info("==> #{f} <==")
          {out, _} = System.cmd("tail", ["-n", "#{opts[:lines] || 100}", f])
          info(out)
        end
    end
  end

  # ── output ───────────────────────────────────────────────────────────────

  defp print_status(config) do
    s = Hosting.status(config)
    pid = if s.pid, do: " (pid #{s.pid})", else: ""
    exit = if s.last_exit && not Hosting.running?(s), do: ", last exit: #{s.last_exit}", else: ""

    info("Loopyard service (#{config.platform}: #{config.label})")
    info("  state     #{s.state}#{pid}#{exit}")
    info("  checkout  #{config.checkout}#{revision(config.checkout)}")
    info("  logs      #{Hosting.service_log(config)}")
    info("            #{Hosting.server_log(config)}")
    info("            (mix loopyard.service logs)\n")

    print_addresses(config, Hosting.port_open?(config.port))
  end

  defp print_addresses(config, listening?) do
    heading =
      if listening?,
        do: "Reachable at",
        else: "Will be reachable at (nothing listens on #{config.port} yet)"

    info("#{heading}:")

    for a <- Addresses.list(config.port, config.bind) do
      note = if a.note, do: "  (#{a.note})", else: ""
      info("  #{String.pad_trailing(Atom.to_string(a.kind), 9)} #{a.url}#{note}")
    end

    :ok
  end

  defp revision(checkout) do
    case System.cmd("git", ["-C", checkout, "log", "-1", "--format=%h %s"],
           stderr_to_stdout: true
         ) do
      {line, 0} -> "\n            at #{String.trim(line)}"
      _ -> ""
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp installed(opts), do: Hosting.installed(opts[:home] || Loopyard.Workspace.home_dir())

  defp installed!(opts) do
    installed(opts) ||
      Mix.raise("the Loopyard service is not installed (mix loopyard.service install)")
  end

  # Long steps (clone, deps.get, compile) say what they are running.
  defp streaming_cmd(cmd, args, opts) do
    if cmd != "git" or hd(args) == "clone", do: info("  $ #{Enum.join([cmd | args], " ")}")
    System.cmd(cmd, args, opts)
  end

  defp ok!(:ok, _what), do: :ok
  defp ok!({:error, why}, what), do: Mix.raise("#{what} failed: #{why}")

  defp info(msg), do: Mix.shell().info(msg)
end
