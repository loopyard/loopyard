defmodule Loopyard.Workstation.EnvSyncHomeTest do
  @moduledoc """
  Syncing env into a home volume must never LOG AGENTS OUT.

  The real incident: `CLAUDE_CODE_OAUTH_TOKEN` lives in the identity's env
  store and is materialized into the `loopyard-ws-<id>-home` Docker volume as
  `~/.loopyard/env`. That volume name is a plain string — it is NOT scoped by
  `LOOPYARD_HOME`. The test suite redirects `LOOPYARD_HOME` to a scratch dir,
  so `read_map/1` found no `env.json`, returned `:absent`, and `sync_home/1`
  cheerfully materialized an EMPTY env file into the developer's REAL home
  volume. Every running agent lost its token and reported "Authentication
  required" — repeatedly, because every `mix test` did it again.

  The rule these tests hold: "I can't find a store" is never a reason to erase
  one. Only a store that EXISTS may assert that it is empty.
  """
  use ExUnit.Case, async: true

  alias Loopyard.Workstation.Env

  test "an absent store refuses to materialize rather than writing an empty env" do
    # No env.json for this id anywhere — exactly the state a process pointed at
    # the wrong LOOPYARD_HOME sees for a real, populated identity.
    assert :absent = Env.read_map("no-such-identity-#{System.unique_integer([:positive])}")

    assert {:error, {:store_absent, _path}} =
             Env.sync_home("no-such-identity-#{System.unique_integer([:positive])}")
  end

  test "an unreadable store also refuses" do
    id = "unreadable-#{System.unique_integer([:positive])}"
    path = Path.join(Loopyard.Workstation.dir(id), "env.json")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "{not json")

    # REMOVE IT. Creating the directory makes this a real identity as far as
    # Workstation.exists?/1 is concerned, so leaving it behind let bootstrap
    # later adopt it as `current` — an identity whose env.json is deliberately
    # corrupt, so Env.keys/1 came back empty and the dashboard correctly
    # reported "no credential". That surfaced as two unrelated first-run tests
    # failing in the full suite and passing alone.
    on_exit(fn -> File.rm_rf(Loopyard.Workstation.dir(id)) end)

    assert {:error, {:store_unreadable, _}} = Env.sync_home(id)
  end
end
