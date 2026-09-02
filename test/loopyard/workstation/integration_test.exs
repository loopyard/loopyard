defmodule Loopyard.Workstation.IntegrationTest do
  use ExUnit.Case, async: false

  alias Loopyard.Workstation
  alias Loopyard.Workstation.{Env, Integration}

  setup do
    prev = System.get_env("LOOPYARD_HOME")
    tmp = Path.join(System.tmp_dir!(), "loopyard-test-#{System.unique_integer([:positive])}")
    System.put_env("LOOPYARD_HOME", tmp)

    on_exit(fn ->
      if prev, do: System.put_env("LOOPYARD_HOME", prev), else: System.delete_env("LOOPYARD_HOME")
      File.rm_rf(tmp)
    end)

    :ok
  end

  describe "registry" do
    test "all/0 + get/1 expose the known tools" do
      ids = Enum.map(Integration.all(), & &1.id)
      assert "github" in ids
      assert "claude" in ids
      assert "codex" in ids
      assert "fly" in ids

      assert Integration.get("codex").label == "Codex"
      assert Integration.get("nope") == nil
    end

    test "every entry has a blurb (so the page always says what it's for)" do
      assert Enum.all?(Integration.all(), &(is_binary(&1.blurb) and &1.blurb != ""))
    end
  end

  describe "mac_script/4 — keychain-aware Mac transfer" do
    test "github: pushes the token to env AND builds a live hosts.yml from it" do
      s = Integration.mac_script(Integration.get("github"), "http://localhost:4000", "brad")
      assert s =~ "gh auth token"
      assert s =~ "http://localhost:4000/workstations/brad/env/GITHUB_TOKEN"
      assert s =~ "http://localhost:4000/workstations/brad/file/.config/gh/hosts.yml"
    end

    test "claude: reads the macOS Keychain (file fallback) + pushes the onboarding config" do
      s = Integration.mac_script(Integration.get("claude"), "https://x.example", "jamie")
      # the gotcha that motivated all this: keychain, not a cat of a missing file
      assert s =~ ~s(security find-generic-password -s "Claude Code-credentials")
      assert s =~ "$HOME/.claude/.credentials.json"
      assert s =~ "https://x.example/workstations/jamie/file/.claude/.credentials.json"
      assert s =~ "https://x.example/workstations/jamie/file/.claude.json"
      assert s =~ "hasCompletedOnboarding"
    end

    test "codex: file with a guard; fly: token to env" do
      cs = Integration.mac_script(Integration.get("codex"), "http://h", "w")
      assert cs =~ "$HOME/.codex/auth.json"
      assert cs =~ "http://h/workstations/w/file/.codex/auth.json"

      fs = Integration.mac_script(Integration.get("fly"), "http://h", "w")
      assert fs =~ "fly auth token"
      assert fs =~ "http://h/workstations/w/env/FLY_ACCESS_TOKEN"
    end

    test "curl_flags are injected (e.g. the push-token header for setup.sh)" do
      s = Integration.mac_script(Integration.get("fly"), "http://h", "w", ~s(-fsS -H "$AUTH"))
      assert s =~ ~s(curl -fsS -H "$AUTH" -T -)
    end
  end

  describe "connected?/2" do
    test ":env-checked tool reflects whether the key is set on that workstation" do
      fly = Integration.get("fly")
      assert fly.check == {:env, "FLY_ACCESS_TOKEN"}

      :ok = Workstation.create("brad")
      refute Integration.connected?(fly, "brad")

      :ok = Env.put("FLY_ACCESS_TOKEN", "fly-token", "brad")
      assert Integration.connected?(fly, "brad")
    end

    test "env is isolated per workstation" do
      fly = Integration.get("fly")
      :ok = Workstation.create("brad")
      :ok = Workstation.create("jamie")
      :ok = Env.put("FLY_ACCESS_TOKEN", "x", "brad")

      assert Integration.connected?(fly, "brad")
      refute Integration.connected?(fly, "jamie")
    end
  end

  describe "doc/1" do
    test "reads the markdown doc shipped in priv for each tool" do
      for ig <- Integration.all() do
        assert {:ok, md} = Integration.doc(ig.id)
        assert is_binary(md) and md != ""
      end

      assert {:error, :not_found} = Integration.doc("nope")
    end
  end

  describe "mac_script/4 — never silently does nothing" do
    # The bug: `fly auth token` fails (not logged in), the `&&` chain
    # short-circuits, curl never runs, and the user sees NOTHING. They fire the
    # command, the page still says "Not connected", and there is no way to tell
    # a broken push from a missing login. Every script must say which one it is.
    test "every script explains itself when the local credential isn't there" do
      for id <- ~w(github claude codex fly) do
        s = Integration.mac_script(Integration.get(id), "http://h", "w")

        assert s =~ "loopyard:",
               "#{id}: no diagnostic — a missing local credential must SAY so, not no-op"
      end
    end

    test "fly names the ONE action that fixes it" do
      s = Integration.mac_script(Integration.get("fly"), "http://h", "w")
      assert s =~ "fly auth login"
    end
  end
end
