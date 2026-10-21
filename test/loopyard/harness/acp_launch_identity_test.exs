defmodule Loopyard.Harness.ACPLaunchIdentityTest do
  @moduledoc """
  The per-agent account reaches the harness launch as a NAME, never a token.

  `~/.profile` sources the container's host identity env; an agent on another
  identity sources `~/.loopyard/env.<identity>` AFTER it so its account wins.
  The token lives in that file inside the volume — the `docker exec` command
  line (which host `ps` can read) carries only `LOOPYARD_IDENTITY=<id>`.
  """
  use ExUnit.Case, async: true

  alias Loopyard.Harness.ACP

  test "exports the identity and sources its env file after ~/.profile" do
    cmd = ACP.docker_exec_cmd("work-1", :claude, identity: "rocketship")

    assert cmd =~ ~s(export LOOPYARD_IDENTITY="rocketship")
    assert cmd =~ ~S(. "$f")
    assert cmd =~ ~S(f="$HOME/.loopyard/env.$LOOPYARD_IDENTITY")

    {profile_at, _} = :binary.match(cmd, ~S(. "$HOME/.profile"))
    {identity_at, _} = :binary.match(cmd, "LOOPYARD_IDENTITY=")

    assert profile_at < identity_at,
           "the identity file must be sourced AFTER ~/.profile so it wins"
  end

  test "the identity file is sourced before the harness's own env exports" do
    # Catalog env (CLAUDE_MODEL_CONFIG, NO_BROWSER) stays authoritative over
    # anything an identity file might set.
    cmd = ACP.docker_exec_cmd("work-1", :codex, identity: "rocketship")
    {identity_at, _} = :binary.match(cmd, "LOOPYARD_IDENTITY=")
    {env_at, _} = :binary.match(cmd, "NO_BROWSER")
    assert identity_at < env_at
  end

  test "a missing file falls through to the profile env (never a broken launch)" do
    cmd = ACP.docker_exec_cmd("work-1", :claude, identity: "rocketship")
    assert cmd =~ ~S(if [ -f "$f" ]; then . "$f"; fi)
  end

  test "the command line never carries a credential" do
    cmd = ACP.docker_exec_cmd("work-1", :claude, identity: "rocketship")

    for key <- Loopyard.Workstation.Env.credential_keys() do
      refute cmd =~ key, "#{key} must reach the harness through the volume file, not argv"
    end

    refute cmd =~ "sk-ant-"
  end

  test "no identity → no identity line (the pre-feature launch, byte for byte)" do
    assert ACP.docker_exec_cmd("work-1", :claude) == ACP.docker_exec_cmd("work-1", :claude, [])
    refute ACP.docker_exec_cmd("work-1", :claude) =~ "LOOPYARD_IDENTITY"
    refute ACP.docker_exec_cmd("work-1", :claude, identity: nil) =~ "LOOPYARD_IDENTITY"
  end

  test "an identity outside the workstation charset is refused, not interpolated" do
    # The id lands inside a single-quoted `sh -c`; only [a-z0-9-] may get there.
    assert_raise ArgumentError, fn ->
      ACP.docker_exec_cmd("work-1", :claude, identity: "x'; rm -rf / #")
    end

    assert_raise ArgumentError, fn ->
      ACP.docker_exec_cmd("work-1", :claude, identity: "Brad")
    end
  end

  test "the launch still goes through docker exec with the harness's adapter" do
    cmd = ACP.docker_exec_cmd("work-1", :codex, identity: "rocketship")
    assert cmd =~ "docker exec -i work-1"
    assert cmd =~ "codex-acp"
  end
end
