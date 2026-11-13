defmodule Loopyard.Hosting do
  @moduledoc """
  Loopyard as an always-on user service — the core behind
  `mix loopyard.service`. Installs, removes, restarts and reports on a macOS
  LaunchAgent (`launchctl`) or a Linux systemd user unit (`systemctl --user`)
  that runs `mix loopyard.server` from a named checkout, so the server
  outlives the terminal or app that used to be its parent and comes back
  after a reboot.

  Everything that touches the outside world is injectable, so tests never
  reach the real service manager:

    * `:runner` — `(cmd, args, opts) -> {output, exit_status}`, the
      `System.cmd/3` shape; every `launchctl` / `systemctl` / `id` call goes
      through it.
    * `:port_open?` — `(port) -> boolean`, whether something already listens.
    * `:platform`, `:user_home`, `:home`, … — see `config/1`.

  The rendered files live in `Loopyard.Hosting.Unit` (pure). The install
  records its choices in `${LOOPYARD_HOME}/service.json` so `status`,
  `restart`, `logs` and `update` act on the installed checkout, not on
  whichever directory they happen to be run from.
  """

  alias Loopyard.Hosting.Unit

  @label "ai.loopyard.server"
  @systemd_unit "loopyard.service"

  @type platform :: :launchd | :systemd
  @type runner :: (String.t(), [String.t()], keyword() -> {String.t(), non_neg_integer()})
  @type config :: %{
          platform: platform(),
          label: String.t(),
          checkout: String.t(),
          home: String.t(),
          user_home: String.t(),
          port: pos_integer(),
          bind: String.t(),
          path: String.t(),
          mix: String.t(),
          lang: String.t(),
          extra_env: [{String.t(), String.t()}]
        }

  # Env vars passed through to the service when set at install time. The
  # rest of the server's settings live in the checkout's `.env` (read by
  # `config/runtime.exs`) or in `${LOOPYARD_HOME}`. Secrets are deliberately
  # NOT on this list: the unit file is world-readable.
  @passthrough_env ~w(LOOPYARD_MCP_PORT LOOPYARD_MCP_URL SSH_PORT)

  # Tools the server shells out to. Their directories are added to the
  # service's PATH at install, so a bare launchd/systemd PATH still finds them.
  @tools ~w(mix elixir erl git docker colima mutagen npm node tailscale cloudflared)

  @fallback_path ~w(/opt/homebrew/bin /usr/local/bin /usr/bin /bin /usr/sbin /sbin)

  # ── configuration ────────────────────────────────────────────────────────

  @doc """
  Build the service configuration. Every key can be overridden; the defaults
  read the current environment: the checkout is the current directory, the
  port and bind address come from `PORT` / `LOOPYARD_BIND` (else 4000 and
  loopback), and `PATH` is assembled from the directories the needed tools
  resolve to right now.
  """
  @spec config(keyword()) :: config()
  def config(overrides \\ []) do
    user_home = Keyword.get_lazy(overrides, :user_home, &System.user_home!/0)
    find = Keyword.get(overrides, :find_executable, &System.find_executable/1)
    mix = Keyword.get_lazy(overrides, :mix, fn -> find.("mix") || "mix" end)

    %{
      platform: Keyword.get_lazy(overrides, :platform, &platform/0),
      label: Keyword.get(overrides, :label, @label),
      checkout: overrides |> Keyword.get_lazy(:checkout, &File.cwd!/0) |> Path.expand(),
      home: overrides |> Keyword.get_lazy(:home, &Loopyard.Workspace.home_dir/0) |> Path.expand(),
      user_home: user_home,
      port: Keyword.get_lazy(overrides, :port, &env_port/0),
      bind: Keyword.get_lazy(overrides, :bind, fn -> env_or("LOOPYARD_BIND", "127.0.0.1") end),
      path: Keyword.get_lazy(overrides, :path, fn -> resolve_path(find) end),
      mix: mix,
      lang: Keyword.get(overrides, :lang, "en_US.UTF-8"),
      extra_env: Keyword.get_lazy(overrides, :extra_env, &passthrough_env/0)
    }
  end

  @doc "The service manager for this OS, or `:unsupported`."
  @spec platform() :: platform() | :unsupported
  def platform do
    case :os.type() do
      {:unix, :darwin} -> :launchd
      {:unix, :linux} -> :systemd
      _ -> :unsupported
    end
  end

  @doc """
  The `PATH` the service runs with: the directory of every tool in `@tools`
  that `find` resolves (in that order, deduplicated), then the standard
  system directories.
  """
  @spec resolve_path((String.t() -> String.t() | nil)) :: String.t()
  def resolve_path(find \\ &System.find_executable/1) do
    @tools
    |> Enum.map(find)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Path.dirname/1)
    |> Kernel.++(@fallback_path)
    |> Enum.uniq()
    |> Enum.join(":")
  end

  defp env_port do
    case Integer.parse(env_or("PORT", "4000")) do
      {n, ""} when n > 0 -> n
      _ -> 4000
    end
  end

  defp env_or(key, default) do
    case System.get_env(key) do
      v when v in [nil, ""] -> default
      v -> v
    end
  end

  defp passthrough_env do
    for key <- @passthrough_env, (v = System.get_env(key)) not in [nil, ""], do: {key, v}
  end

  # ── paths ────────────────────────────────────────────────────────────────

  @doc "Where the service-manager file goes (plist or unit)."
  @spec unit_path(config()) :: String.t()
  def unit_path(%{platform: :launchd} = c),
    do: Path.join([c.user_home, "Library", "LaunchAgents", c.label <> ".plist"])

  def unit_path(%{platform: :systemd} = c),
    do: Path.join([c.user_home, ".config", "systemd", "user", @systemd_unit])

  @doc "The launch script the unit runs."
  @spec script_path(config()) :: String.t()
  def script_path(c), do: Path.join([c.home, "service", "run.sh"])

  @doc "The service's log directory."
  @spec log_dir(config()) :: String.t()
  def log_dir(c), do: Path.join(c.home, "logs")

  @doc "The server's own (Logger) log — rotated by the server itself."
  @spec server_log(config()) :: String.t()
  def server_log(c), do: Path.join(log_dir(c), "server.log")

  @doc "The service's stdout/stderr log — rotated by the launch script at start."
  @spec service_log(config()) :: String.t()
  def service_log(c), do: Path.join(log_dir(c), "service.log")

  @doc "Where the installed configuration is recorded."
  @spec state_path(String.t()) :: String.t()
  def state_path(home), do: Path.join(home, "service.json")

  # ── persisted install record ─────────────────────────────────────────────

  @doc """
  The configuration recorded by the last install under `home`, or `nil`.
  `status`/`restart`/`update` act on THIS, so they reach the installed
  checkout whatever directory they run from.
  """
  @spec installed(String.t()) :: config() | nil
  def installed(home \\ Loopyard.Workspace.home_dir()) do
    with {:ok, json} <- File.read(state_path(home)),
         {:ok, m} <- Jason.decode(json) do
      %{
        platform: if(m["platform"] == "systemd", do: :systemd, else: :launchd),
        label: m["label"],
        checkout: m["checkout"],
        home: m["home"],
        user_home: m["user_home"],
        port: m["port"],
        bind: m["bind"],
        path: m["path"],
        mix: m["mix"],
        lang: m["lang"],
        extra_env: Enum.map(m["extra_env"] || [], fn [k, v] -> {k, v} end)
      }
    else
      _ -> nil
    end
  end

  defp record!(config) do
    json =
      config
      |> Map.update!(:platform, &Atom.to_string/1)
      |> Map.update!(:extra_env, fn env -> Enum.map(env, &Tuple.to_list/1) end)
      |> Jason.encode!(pretty: true)

    File.mkdir_p!(config.home)
    File.write!(state_path(config.home), json)
  end

  # ── lifecycle ────────────────────────────────────────────────────────────

  @doc """
  Write the launch script and the unit, record the configuration and load the
  service (which starts it — RunAtLoad / `enable --now`).

  REFUSES when something other than this service already listens on the
  port: the usual case is a `mix loopyard.server` left running in a terminal.
  Loading anyway would crash-loop the service every ten seconds, and each
  boot's stale-harness reap (scoped to the Loopyard home, which both share)
  would kill that server's live agent harnesses.
  """
  @spec install(config(), keyword()) :: :ok | {:error, String.t()}
  def install(config, opts \\ []) do
    runner = runner(opts)
    port_open? = Keyword.get(opts, :port_open?, &port_open?/1)

    cond do
      not File.dir?(Path.join(config.checkout, ".git")) and
          not File.regular?(Path.join(config.checkout, ".git")) ->
        {:error, "#{config.checkout} is not a git checkout of Loopyard"}

      not File.regular?(Path.join(config.checkout, "mix.exs")) ->
        {:error, "#{config.checkout} has no mix.exs: not a Loopyard checkout"}

      port_open?.(config.port) and not running?(status(config, opts)) ->
        {:error,
         "Port #{config.port} is already in use by a server this service didn't start " <>
           "(probably `mix loopyard.server` in a terminal). Stop it, then run install again."}

      true ->
        write_files!(config)
        record!(config)
        load(config, runner)
    end
  end

  defp write_files!(config) do
    script = script_path(config)
    File.mkdir_p!(Path.dirname(script))
    File.mkdir_p!(log_dir(config))
    File.write!(script, Unit.script(config))
    File.chmod!(script, 0o755)

    unit = unit_path(config)
    File.mkdir_p!(Path.dirname(unit))

    body =
      case config.platform do
        :launchd -> Unit.plist(config)
        :systemd -> Unit.systemd(config)
      end

    File.write!(unit, body)
  end

  defp load(%{platform: :launchd} = c, runner) do
    domain = gui_domain(runner)
    # A reinstall replaces the loaded definition; a first install has nothing
    # to boot out, so that failure is expected and ignored.
    _ = runner.("launchctl", ["bootout", "#{domain}/#{c.label}"], stderr_to_stdout: true)

    with :ok <-
           ok(runner.("launchctl", ["bootstrap", domain, unit_path(c)], stderr_to_stdout: true)) do
      ok(runner.("launchctl", ["enable", "#{domain}/#{c.label}"], stderr_to_stdout: true))
    end
  end

  defp load(%{platform: :systemd}, runner) do
    with :ok <- systemctl(runner, ["daemon-reload"]) do
      systemctl(runner, ["enable", "--now", @systemd_unit])
    end
  end

  @doc "Stop and unload the service and delete its files. Logs are kept."
  @spec uninstall(config(), keyword()) :: :ok | {:error, String.t()}
  def uninstall(config, opts \\ []) do
    runner = runner(opts)

    case config.platform do
      :launchd ->
        _ =
          runner.("launchctl", ["bootout", "#{gui_domain(runner)}/#{config.label}"],
            stderr_to_stdout: true
          )

      :systemd ->
        _ = systemctl(runner, ["disable", "--now", @systemd_unit])
    end

    File.rm(unit_path(config))
    File.rm(script_path(config))
    File.rm(state_path(config.home))

    if config.platform == :systemd, do: _ = systemctl(runner, ["daemon-reload"])
    :ok
  end

  @doc "Restart the running service (start it if it is loaded but stopped)."
  @spec restart(config(), keyword()) :: :ok | {:error, String.t()}
  def restart(config, opts \\ []) do
    runner = runner(opts)

    case config.platform do
      :launchd ->
        ok(
          runner.("launchctl", ["kickstart", "-k", "#{gui_domain(runner)}/#{config.label}"],
            stderr_to_stdout: true
          )
        )

      :systemd ->
        systemctl(runner, ["restart", @systemd_unit])
    end
  end

  @type status :: %{
          installed?: boolean(),
          loaded?: boolean(),
          state: String.t(),
          pid: pos_integer() | nil,
          last_exit: String.t() | nil
        }

  @doc "What the service manager says about the service."
  @spec status(config(), keyword()) :: status()
  def status(config, opts \\ []) do
    runner = runner(opts)
    installed? = File.regular?(unit_path(config))

    case config.platform do
      :launchd ->
        case runner.("launchctl", ["print", "#{gui_domain(runner)}/#{config.label}"],
               stderr_to_stdout: true
             ) do
          {out, 0} ->
            Map.put(parse_launchctl(out), :installed?, installed?)

          _ ->
            %{
              installed?: installed?,
              loaded?: false,
              state: "not loaded",
              pid: nil,
              last_exit: nil
            }
        end

      :systemd ->
        {out, _} =
          runner.(
            "systemctl",
            [
              "--user",
              "show",
              @systemd_unit,
              "--property=LoadState,ActiveState,SubState,MainPID,ExecMainStatus"
            ],
            stderr_to_stdout: true
          )

        Map.put(parse_systemctl(out), :installed?, installed?)
    end
  end

  @doc "Is the service process up?"
  @spec running?(status()) :: boolean()
  def running?(%{state: state}), do: state in ["running", "active (running)"]

  @doc false
  @spec parse_launchctl(String.t()) :: map()
  def parse_launchctl(out) do
    field = fn re ->
      case Regex.run(re, out) do
        [_, v] -> String.trim(v)
        _ -> nil
      end
    end

    pid =
      case field.(~r/^\s*pid = (\d+)/m) do
        nil -> nil
        n -> String.to_integer(n)
      end

    %{
      loaded?: true,
      state: field.(~r/^\s*state = (.+)$/m) || "unknown",
      pid: pid,
      last_exit: field.(~r/^\s*last exit code = (.+)$/m)
    }
  end

  @doc false
  @spec parse_systemctl(String.t()) :: map()
  def parse_systemctl(out) do
    props =
      for line <- String.split(out, "\n", trim: true),
          [k, v] <- [String.split(line, "=", parts: 2)],
          into: %{},
          do: {k, String.trim(v)}

    pid =
      case Integer.parse(props["MainPID"] || "0") do
        {n, _} when n > 0 -> n
        _ -> nil
      end

    active = props["ActiveState"] || "unknown"
    sub = props["SubState"]

    %{
      loaded?: props["LoadState"] == "loaded",
      state: if(sub, do: "#{active} (#{sub})", else: active),
      pid: pid,
      last_exit: props["ExecMainStatus"]
    }
  end

  # ── plumbing ─────────────────────────────────────────────────────────────

  @doc false
  def runner(opts), do: Keyword.get(opts, :runner, &System.cmd/3)

  @doc "Does anything accept TCP connections on 127.0.0.1:`port`?"
  @spec port_open?(pos_integer()) :: boolean()
  def port_open?(port) do
    case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 500) do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        true

      _ ->
        false
    end
  end

  defp gui_domain(runner) do
    case runner.("id", ["-u"], []) do
      {uid, 0} -> "gui/" <> String.trim(uid)
      _ -> "gui/#{System.get_env("UID", "501")}"
    end
  end

  defp systemctl(runner, args),
    do: ok(runner.("systemctl", ["--user" | args], stderr_to_stdout: true))

  defp ok({_out, 0}), do: :ok
  defp ok({out, status}), do: {:error, "exit #{status}: #{String.trim(out)}"}
end
