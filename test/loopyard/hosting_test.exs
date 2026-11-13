defmodule Loopyard.HostingTest do
  # Every service-manager call goes through a fake runner: these tests never
  # reach the real launchctl / systemctl.
  use ExUnit.Case, async: true

  alias Loopyard.Hosting

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    checkout = Path.join(tmp, "checkout")
    File.mkdir_p!(Path.join(checkout, ".git"))
    File.write!(Path.join(checkout, "mix.exs"), "")
    %{checkout: checkout}
  end

  defp config(tmp, checkout, overrides \\ []) do
    Hosting.config(
      Keyword.merge(
        [
          platform: :launchd,
          user_home: Path.join(tmp, "home"),
          home: Path.join(tmp, "home/.loopyard"),
          checkout: checkout,
          port: 4100,
          bind: "127.0.0.1",
          path: "/usr/bin:/bin",
          mix: "/usr/local/bin/mix",
          extra_env: []
        ],
        overrides
      )
    )
  end

  # Records every call to the test process; answers from `responses` (a fn of
  # cmd + args — a call no clause matches succeeds with empty output).
  defp runner(responses \\ fn _, _ -> nil end) do
    test = self()

    fn cmd, args, _opts ->
      send(test, {:cmd, cmd, args})

      case {cmd, args} do
        {"id", ["-u"]} -> {"501\n", 0}
        _ -> answer(responses, cmd, args)
      end
    end
  end

  defp answer(responses, cmd, args) do
    responses.(cmd, args) || {"", 0}
  rescue
    FunctionClauseError -> {"", 0}
  end

  defp calls do
    receive do
      {:cmd, cmd, args} -> [{cmd, args} | calls()]
    after
      0 -> []
    end
  end

  @running """
  gui/501/ai.loopyard.server = {
  \tactive count = 1
  \tpath = /Users/me/Library/LaunchAgents/ai.loopyard.server.plist
  \tstate = running
  \tprogram = /bin/sh
  \tpid = 4242
  \tlast exit code = (never exited)
  }
  """

  describe "config/1" do
    test "defaults the checkout to the current directory", %{tmp_dir: tmp} do
      c = Hosting.config(user_home: tmp, home: tmp, path: "/bin", mix: "mix", extra_env: [])
      assert c.checkout == File.cwd!()
      assert c.label == "ai.loopyard.server"
    end

    test "PATH holds the resolved tool dirs first, then the system ones" do
      find = fn
        "mix" -> "/opt/elixir/bin/mix"
        "erl" -> "/opt/erlang/bin/erl"
        "docker" -> "/opt/homebrew/bin/docker"
        _ -> nil
      end

      path = Hosting.resolve_path(find)
      assert String.starts_with?(path, "/opt/elixir/bin:/opt/erlang/bin:/opt/homebrew/bin:")
      assert path =~ ":/usr/bin:/bin:"
      # Deduplicated: /opt/homebrew/bin appears once.
      assert length(String.split(path, "/opt/homebrew/bin")) == 2
    end
  end

  describe "install/2 (launchd)" do
    test "writes script + plist, records the config, bootstraps and enables",
         %{tmp_dir: tmp, checkout: checkout} do
      c = config(tmp, checkout)

      assert :ok = Hosting.install(c, runner: runner(), port_open?: fn _ -> false end)

      assert File.read!(Hosting.unit_path(c)) =~ "<string>ai.loopyard.server</string>"

      assert Hosting.unit_path(c) ==
               Path.join(tmp, "home/Library/LaunchAgents/ai.loopyard.server.plist")

      assert File.stat!(Hosting.script_path(c)).mode |> Bitwise.band(0o111) != 0
      assert File.dir?(Hosting.log_dir(c))
      assert Hosting.installed(c.home) == c

      cmds = calls() |> Enum.reject(&match?({"id", _}, &1))

      assert cmds == [
               {"launchctl", ["bootout", "gui/501/ai.loopyard.server"]},
               {"launchctl", ["bootstrap", "gui/501", Hosting.unit_path(c)]},
               {"launchctl", ["enable", "gui/501/ai.loopyard.server"]}
             ]
    end

    test "refuses while a server it didn't start holds the port", %{
      tmp_dir: tmp,
      checkout: checkout
    } do
      c = config(tmp, checkout)
      not_loaded = runner(fn "launchctl", ["print" | _] -> {"Could not find service", 113} end)

      assert {:error, why} =
               Hosting.install(c, runner: not_loaded, port_open?: fn 4100 -> true end)

      assert why =~ "Port 4100 is already in use"
      refute File.exists?(Hosting.unit_path(c))
      refute Enum.any?(calls(), &match?({"launchctl", ["bootstrap" | _]}, &1))
    end

    test "a reinstall over its own running service goes ahead", %{
      tmp_dir: tmp,
      checkout: checkout
    } do
      c = config(tmp, checkout)
      running = runner(fn "launchctl", ["print" | _] -> {@running, 0} end)

      assert :ok = Hosting.install(c, runner: running, port_open?: fn _ -> true end)
    end

    test "refuses a directory that isn't a Loopyard checkout", %{tmp_dir: tmp} do
      c = config(tmp, tmp)
      assert {:error, why} = Hosting.install(c, runner: runner(), port_open?: fn _ -> false end)
      assert why =~ "not a git checkout"
    end

    test "surfaces a failed bootstrap", %{tmp_dir: tmp, checkout: checkout} do
      c = config(tmp, checkout)

      failing =
        runner(fn "launchctl", ["bootstrap" | _] ->
          {"Bootstrap failed: 5: Input/output error", 5}
        end)

      assert {:error, "exit 5: Bootstrap failed" <> _} =
               Hosting.install(c, runner: failing, port_open?: fn _ -> false end)
    end
  end

  describe "status/2, restart/2, uninstall/2 (launchd)" do
    setup %{tmp_dir: tmp, checkout: checkout} do
      c = config(tmp, checkout)
      :ok = Hosting.install(c, runner: runner(), port_open?: fn _ -> false end)
      _ = calls()
      %{c: c}
    end

    test "status parses launchctl print", %{c: c} do
      s = Hosting.status(c, runner: runner(fn "launchctl", ["print" | _] -> {@running, 0} end))

      assert s == %{
               installed?: true,
               loaded?: true,
               state: "running",
               pid: 4242,
               last_exit: "(never exited)"
             }

      assert Hosting.running?(s)
    end

    test "status of an unloaded service", %{c: c} do
      s =
        Hosting.status(c,
          runner: runner(fn "launchctl", ["print" | _] -> {"Could not find", 113} end)
        )

      assert %{loaded?: false, state: "not loaded", pid: nil} = s
      refute Hosting.running?(s)
    end

    test "restart kickstarts with -k", %{c: c} do
      assert :ok = Hosting.restart(c, runner: runner())
      assert {"launchctl", ["kickstart", "-k", "gui/501/ai.loopyard.server"]} in calls()
    end

    test "uninstall boots it out and removes its files but keeps logs", %{c: c} do
      File.write!(Hosting.service_log(c), "old run\n")

      assert :ok = Hosting.uninstall(c, runner: runner())
      assert {"launchctl", ["bootout", "gui/501/ai.loopyard.server"]} in calls()
      refute File.exists?(Hosting.unit_path(c))
      refute File.exists?(Hosting.script_path(c))
      assert Hosting.installed(c.home) == nil
      assert File.read!(Hosting.service_log(c)) == "old run\n"
    end
  end

  describe "systemd" do
    test "install writes the user unit, reloads and enables --now", %{
      tmp_dir: tmp,
      checkout: checkout
    } do
      c = config(tmp, checkout, platform: :systemd)

      inactive =
        runner(fn "systemctl", ["--user", "show" | _] ->
          {"LoadState=not-found\nActiveState=inactive\n", 0}
        end)

      assert :ok = Hosting.install(c, runner: inactive, port_open?: fn _ -> false end)
      assert Hosting.unit_path(c) == Path.join(tmp, "home/.config/systemd/user/loopyard.service")
      assert File.read!(Hosting.unit_path(c)) =~ "Restart=always"

      cmds = calls()
      assert {"systemctl", ["--user", "daemon-reload"]} in cmds
      assert {"systemctl", ["--user", "enable", "--now", "loopyard.service"]} in cmds
      assert Hosting.installed(c.home).platform == :systemd
    end

    test "status parses systemctl show", %{tmp_dir: tmp, checkout: checkout} do
      c = config(tmp, checkout, platform: :systemd)

      out =
        "LoadState=loaded\nActiveState=active\nSubState=running\nMainPID=777\nExecMainStatus=0\n"

      s = Hosting.status(c, runner: runner(fn "systemctl", _ -> {out, 0} end))

      assert %{loaded?: true, state: "active (running)", pid: 777} = s
      assert Hosting.running?(s)
    end

    test "restart and uninstall", %{tmp_dir: tmp, checkout: checkout} do
      c = config(tmp, checkout, platform: :systemd)
      assert :ok = Hosting.restart(c, runner: runner())
      assert :ok = Hosting.uninstall(c, runner: runner())

      cmds = calls()
      assert {"systemctl", ["--user", "restart", "loopyard.service"]} in cmds
      assert {"systemctl", ["--user", "disable", "--now", "loopyard.service"]} in cmds
    end
  end

  test "port_open?/1 sees a real listener" do
    {:ok, sock} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(sock)
    assert Hosting.port_open?(port)
    :gen_tcp.close(sock)
    refute Hosting.port_open?(port)
  end
end
