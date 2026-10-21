defmodule Loopyard.Workstation.EnvIdentityTest do
  @moduledoc """
  Per-identity env files (`~/.loopyard/env.<identity>`): what they contain and
  when they may be written. The same "never erase a credential by accident"
  rules as `sync_home/1` (see `EnvSyncHomeTest`) apply to writing one
  identity's env into another identity's home.
  """
  use ExUnit.Case, async: true

  alias Loopyard.Workstation.Env

  describe "identity_file_body/1" do
    test "unsets every harness credential before exporting its own" do
      body = Env.identity_file_body(%{"CLAUDE_CODE_OAUTH_TOKEN" => "tok-b", "GH_TOKEN" => "gh"})
      [unset_line | exports] = String.split(body, "\n")

      # Every key a harness in the Catalog signs in with — so an agent on this
      # identity can't inherit the container host's token via ~/.profile.
      assert unset_line =~ "unset "

      for key <- Env.credential_keys() do
        assert unset_line =~ key
      end

      assert "export CLAUDE_CODE_OAUTH_TOKEN='tok-b'" in exports
      assert "export GH_TOKEN='gh'" in exports
    end

    test "credential_keys/0 covers every Catalog harness" do
      keys = Env.credential_keys()

      for harness <- Loopyard.Harness.Catalog.all(), key <- harness.credential_keys do
        assert key in keys
      end
    end

    test "a value containing a quote survives" do
      body = Env.identity_file_body(%{"K" => "it's"})
      assert body =~ ~S(export K='it'\''s')
    end
  end

  describe "identity_file/1" do
    test "names the file by identity under ~/.loopyard" do
      assert Env.identity_file("rocketship") == ".loopyard/env.rocketship"
    end
  end

  describe "sync_identity_into/2 refuses rather than erase" do
    test "an absent store writes nothing" do
      id = "no-such-identity-#{System.unique_integer([:positive])}"
      assert {:error, {:store_absent, _}} = Env.sync_identity_into(id, "host-#{id}")
    end

    test "an unreadable store writes nothing" do
      id = "unreadable-#{System.unique_integer([:positive])}"
      path = Path.join(Loopyard.Workstation.dir(id), "env.json")
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "{not json")
      on_exit(fn -> File.rm_rf(Loopyard.Workstation.dir(id)) end)

      assert {:error, {:store_unreadable, _}} = Env.sync_identity_into(id, "host-#{id}")
    end

    test "an empty store writes nothing" do
      id = "empty-#{System.unique_integer([:positive])}"
      path = Path.join(Loopyard.Workstation.dir(id), "env.json")
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "{}")
      on_exit(fn -> File.rm_rf(Loopyard.Workstation.dir(id)) end)

      assert {:error, :refusing_empty_env} = Env.sync_identity_into(id, "host-#{id}")
    end

    test "the same identity is a plain sync_home (same refusals)" do
      id = "same-#{System.unique_integer([:positive])}"
      assert Env.sync_identity_into(id, id) == Env.sync_home(id)
    end
  end
end
