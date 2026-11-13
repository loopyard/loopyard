defmodule Loopyard.Hosting.UnitTest do
  use ExUnit.Case, async: true

  alias Loopyard.Hosting
  alias Loopyard.Hosting.Unit

  @moduletag :tmp_dir

  defp config(tmp, overrides \\ []) do
    Hosting.config(
      Keyword.merge(
        [
          platform: :launchd,
          user_home: Path.join(tmp, "home"),
          home: Path.join(tmp, "home/.loopyard"),
          checkout: Path.join(tmp, "loopyard server"),
          port: 4100,
          bind: "127.0.0.1",
          path: "/opt/erlang/bin:/usr/bin:/bin",
          mix: "/opt/elixir/bin/mix",
          extra_env: []
        ],
        overrides
      )
    )
  end

  describe "env/1" do
    test "carries exactly what the server needs", %{tmp_dir: tmp} do
      env = Map.new(Unit.env(config(tmp)))

      assert env["PATH"] == "/opt/erlang/bin:/usr/bin:/bin"
      assert env["HOME"] == Path.join(tmp, "home")
      assert env["LOOPYARD_HOME"] == Path.join(tmp, "home/.loopyard")
      assert env["LOOPYARD_BIND"] == "127.0.0.1"
      assert env["PORT"] == "4100"
      assert env["LANG"] =~ "UTF-8"
      assert env["LOOPYARD_LOG_FILE"] == Path.join(tmp, "home/.loopyard/logs/server.log")
      assert env["MIX_ENV"] == "dev"
    end

    test "passes extra env through", %{tmp_dir: tmp} do
      env = Unit.env(config(tmp, extra_env: [{"LOOPYARD_MCP_PORT", "4031"}]))
      assert {"LOOPYARD_MCP_PORT", "4031"} in env
    end
  end

  describe "script/1" do
    test "rotates the stdout log, then runs the server from the checkout", %{tmp_dir: tmp} do
      script = Unit.script(config(tmp))

      assert script =~ "#!/bin/sh"
      assert script =~ "-gt #{Unit.stdout_cap_bytes()}"
      assert script =~ ~s(mv -f "$log" "$log.1")
      # Rotation happens BEFORE the log is opened for this run.
      assert :binary.match(script, "mv -f") < :binary.match(script, "exec >>")
      assert script =~ "cd '#{Path.join(tmp, "loopyard server")}' || exit 78"
      assert script =~ "exec '/opt/elixir/bin/mix' loopyard.server"
    end

    test "is valid sh and survives quotes in paths", %{tmp_dir: tmp} do
      path = Path.join(tmp, "run.sh")
      File.write!(path, Unit.script(config(tmp, checkout: Path.join(tmp, "it's here"))))
      assert {_, 0} = System.cmd("sh", ["-n", path], stderr_to_stdout: true)
      assert File.read!(path) =~ ~S(it'\''s here' || exit 78)
    end

    test "rotates for real past the cap", %{tmp_dir: tmp} do
      # Run the script's rotation prelude against a real oversized log, with
      # the server command swapped for `true`.
      c = config(tmp, mix: "/usr/bin/true", checkout: tmp)
      log_dir = Hosting.log_dir(c)
      File.mkdir_p!(log_dir)

      File.write!(
        Path.join(log_dir, "service.log"),
        :binary.copy("x", Unit.stdout_cap_bytes() + 1)
      )

      script = Path.join(tmp, "run.sh")

      File.write!(
        script,
        String.replace(Unit.script(c), "exec '/usr/bin/true' loopyard.server", "true")
      )

      assert {_, 0} = System.cmd("sh", [script])

      assert File.stat!(Path.join(log_dir, "service.log.1")).size > Unit.stdout_cap_bytes()
      assert File.read!(Path.join(log_dir, "service.log")) =~ "[loopyard.service]"
    end
  end

  describe "plist/1" do
    test "runs the script at load, keeps it alive, with the environment", %{tmp_dir: tmp} do
      c = config(tmp)
      plist = Unit.plist(c)

      assert plist =~ "<string>ai.loopyard.server</string>"
      assert plist =~ "<string>#{Hosting.script_path(c)}</string>"
      assert plist =~ "<key>RunAtLoad</key>\n  <true/>"
      assert plist =~ "<key>KeepAlive</key>\n  <true/>"
      assert plist =~ "<key>PORT</key>\n      <string>4100</string>"
      assert plist =~ "<key>WorkingDirectory</key>\n  <string>#{c.checkout}</string>"
    end

    test "escapes XML in values", %{tmp_dir: tmp} do
      plist = Unit.plist(config(tmp, checkout: Path.join(tmp, "a&b<c>")))
      assert plist =~ "a&amp;b&lt;c&gt;"
      refute plist =~ "a&b<c>"
    end

    if System.find_executable("plutil") do
      test "passes plutil -lint", %{tmp_dir: tmp} do
        path = Path.join(tmp, "ai.loopyard.server.plist")
        File.write!(path, Unit.plist(config(tmp, checkout: Path.join(tmp, "a&b \"q\""))))
        assert {out, 0} = System.cmd("plutil", ["-lint", path], stderr_to_stdout: true)
        assert out =~ "OK"
      end
    end
  end

  describe "systemd/1" do
    test "restarts forever and quotes specifiers", %{tmp_dir: tmp} do
      unit = Unit.systemd(config(tmp, platform: :systemd, path: "/a%b:$HOME/bin"))

      assert unit =~ "Restart=always"
      assert unit =~ "StartLimitIntervalSec=0"
      assert unit =~ "WantedBy=default.target"
      # % is a specifier everywhere; $ is only expanded in ExecStart=.
      assert unit =~ ~s(Environment="PATH=/a%%b:$HOME/bin")
      assert unit =~ ~s(ExecStart=/bin/sh ")
    end
  end
end
