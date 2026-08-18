defmodule Loopyard.DockerGuardTest do
  @moduledoc """
  `guard_real_resources!` must refuse a MUTATING docker command that names a
  real (non-test-prefixed) container/volume, while allowing test-prefixed
  resources and host filesystem paths (issue #82 / H1).

  Exercised through `Docker.docker/2`: in the test env the guard runs before
  the `docker disabled` gate, so a safe command returns the disabled tuple and
  an unsafe one raises.
  """
  use ExUnit.Case, async: true

  alias Loopyard.Docker

  defp guarded(args) do
    Docker.docker(args)
    :allowed
  rescue
    RuntimeError -> :refused
  end

  test "refuses a real (non-test) volume name on a mutating command" do
    assert :refused = guarded(["volume", "rm", "loopyard-realvol"])
  end

  test "refuses a real name given in Docker's leading-slash form (/name)" do
    # `docker volume rm /loopyard-realvol` resolves to `loopyard-realvol` —
    # the leading-slash exemption used to wave this through.
    assert :refused = guarded(["volume", "rm", "/loopyard-realvol"])
    assert :refused = guarded(["rm", "-f", "/loopyard-realcontainer"])
  end

  test "refuses a shared-artifact prefix collision (…-base-EVIL)" do
    # @shared_artifacts must match exactly, not by prefix.
    assert :refused = guarded(["rm", "loopyard-workspace-base-EVIL"])
  end

  test "ALLOWS a test-prefixed resource" do
    assert :allowed = guarded(["volume", "rm", "loopyard-test-vol"])
  end

  test "ALLOWS the shared build-artifact image (exact)" do
    assert :allowed = guarded(["rmi", "loopyard-workspace-base"])
    assert :allowed = guarded(["rmi", "loopyard-workspace-base:v1"])
  end

  test "ALLOWS a host filesystem path that contains loopyard-<x>" do
    # A compose file under a worktree dir named loopyard-reliability is a
    # PATH, not a resource — it must not false-positive.
    assert :allowed =
             guarded([
               "compose",
               "-f",
               "/Users/x/Projects/loopyard/loopyard-reliability/dc.yml",
               "-p",
               "loopyard-test-x",
               "up"
             ])

    assert :allowed =
             guarded(["run", "-v", "/Users/x/loopyard-reliability/code:/workspace", "img"])
  end

  test "reads are never guarded (ps/inspect/logs)" do
    assert :allowed = guarded(["ps", "--filter", "name=loopyard-realvol"])
  end
end
