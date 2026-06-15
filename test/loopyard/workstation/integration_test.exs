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

  describe "mac_command/3 — the Mac-first default" do
    test "env target pipes a producer into the env push endpoint" do
      gh = Integration.get("github")

      assert Integration.mac_command(gh, "http://localhost:4000", "brad") ==
               "gh auth token | curl -fsS -T - http://localhost:4000/workstations/brad/env/GITHUB_TOKEN"
    end

    test "file target pipes a producer into the file push endpoint" do
      codex = Integration.get("codex")

      assert Integration.mac_command(codex, "https://x.example", "jamie") ==
               "cat ~/.codex/auth.json | curl -fsS -T - https://x.example/workstations/jamie/file/.codex/auth.json"
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
end
