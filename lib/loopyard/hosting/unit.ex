defmodule Loopyard.Hosting.Unit do
  @moduledoc """
  Pure renderers for the files `mix loopyard.service install` writes: the
  launch script both service managers run, the macOS LaunchAgent plist and
  the Linux systemd user unit. Every function takes a `t:Loopyard.Hosting.config/0`
  and returns a string — no I/O, so tests render and inspect them freely.

  ## Why a script between the manager and `mix`

  The script is the ONE place the start-up shape lives, so the plist and the
  unit stay a thin "run this, keep it alive, with this environment" and never
  need shell quoting rules of their own (systemd expands `$` and `%` in
  `ExecStart`; a plist is XML). It also owns the stdout log's size cap: the
  file is rotated to `service.log.1` past `@stdout_cap_bytes` on every start,
  BEFORE it is opened, so the open descriptor never points at a moved file.
  `service.log` only carries what isn't a Logger event (boot banner, compile
  output, a crash before the logger is up); the server's own log goes to a
  rotating Logger handler (`LOOPYARD_LOG_FILE`, see `mix loopyard.server`).
  """

  @stdout_cap_bytes 1_048_576

  @doc "The size past which `service.log` is rotated at start."
  @spec stdout_cap_bytes() :: pos_integer()
  def stdout_cap_bytes, do: @stdout_cap_bytes

  @doc """
  The environment the server runs with. Only what it needs: a `PATH` resolved
  at install time (launchd and systemd start with a bare one, so Erlang,
  Elixir, git, docker and colima would otherwise be missing), the Loopyard
  home, port and bind address, `HOME`, a UTF-8 `LANG` (the BEAM warns and
  mangles output without one) and where the rotating server log goes.
  """
  @spec env(Loopyard.Hosting.config()) :: [{String.t(), String.t()}]
  def env(config) do
    [
      {"PATH", config.path},
      {"HOME", config.user_home},
      {"LANG", config.lang},
      {"LOOPYARD_HOME", config.home},
      {"LOOPYARD_BIND", config.bind},
      {"PORT", Integer.to_string(config.port)},
      {"LOOPYARD_LOG_FILE", Loopyard.Hosting.server_log(config)},
      {"MIX_ENV", "dev"}
    ] ++ config.extra_env
  end

  @doc "The POSIX shell script the service manager runs."
  @spec script(Loopyard.Hosting.config()) :: String.t()
  def script(config) do
    log_dir = Loopyard.Hosting.log_dir(config)

    """
    #!/bin/sh
    # Written by `mix loopyard.service install` — re-run install to change it.
    log_dir=#{sh(log_dir)}
    log="$log_dir/service.log"
    mkdir -p "$log_dir"
    if [ -f "$log" ] && [ "$(wc -c < "$log")" -gt #{@stdout_cap_bytes} ]; then
      mv -f "$log" "$log.1"
    fi
    exec >>"$log" 2>&1
    echo "[loopyard.service] $(date '+%Y-%m-%d %H:%M:%S') starting from #{sh(config.checkout)}"
    cd #{sh(config.checkout)} || exit 78
    exec #{sh(config.mix)} loopyard.server
    """
  end

  @doc "The LaunchAgent plist (RunAtLoad + KeepAlive) that runs `script/1`."
  @spec plist(Loopyard.Hosting.config()) :: String.t()
  def plist(config) do
    env =
      Enum.map_join(env(config), "\n", fn {k, v} ->
        "      <key>#{xml(k)}</key>\n      <string>#{xml(v)}</string>"
      end)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key>
      <string>#{xml(config.label)}</string>
      <key>ProgramArguments</key>
      <array>
        <string>/bin/sh</string>
        <string>#{xml(Loopyard.Hosting.script_path(config))}</string>
      </array>
      <key>WorkingDirectory</key>
      <string>#{xml(config.checkout)}</string>
      <key>EnvironmentVariables</key>
      <dict>
    #{env}
      </dict>
      <key>RunAtLoad</key>
      <true/>
      <key>KeepAlive</key>
      <true/>
      <key>ThrottleInterval</key>
      <integer>10</integer>
      <key>ProcessType</key>
      <string>Interactive</string>
      <key>StandardOutPath</key>
      <string>#{xml(Path.join(Loopyard.Hosting.log_dir(config), "launchd.log"))}</string>
      <key>StandardErrorPath</key>
      <string>#{xml(Path.join(Loopyard.Hosting.log_dir(config), "launchd.log"))}</string>
    </dict>
    </plist>
    """
  end

  @doc "The systemd user unit that runs `script/1`, restarting it forever."
  @spec systemd(Loopyard.Hosting.config()) :: String.t()
  def systemd(config) do
    env =
      Enum.map_join(env(config), "\n", fn {k, v} ->
        "Environment=" <> systemd_quote("#{k}=#{v}", :env)
      end)

    """
    [Unit]
    Description=Loopyard (#{config.checkout})
    After=network-online.target
    StartLimitIntervalSec=0

    [Service]
    Type=simple
    WorkingDirectory=#{systemd_path(config.checkout)}
    #{env}
    ExecStart=/bin/sh #{systemd_quote(Loopyard.Hosting.script_path(config), :exec)}
    Restart=always
    RestartSec=10

    [Install]
    WantedBy=default.target
    """
  end

  # Single-quote for POSIX sh: close, escaped quote, reopen.
  defp sh(value), do: "'" <> String.replace(value, "'", ~S('\'')) <> "'"

  defp xml(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  # systemd expands `%` specifiers in both Environment= and ExecStart=, and
  # `$VAR` only in ExecStart=; each is doubled where it would be expanded.
  defp systemd_quote(value, where) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("%", "%%")

    escaped = if where == :exec, do: String.replace(escaped, "$", "$$"), else: escaped

    "\"" <> escaped <> "\""
  end

  defp systemd_path(value), do: String.replace(value, "%", "%%")
end
