defmodule Loopyard.CanonicalRepoTest do
  @moduledoc """
  Exercises the hub-and-spokes git engine against REAL git + Docker volumes.
  Tagged :docker (excluded from the default suite) — run with:

      mix test --include docker test/loopyard/canonical_repo_test.exs
  """
  use ExUnit.Case, async: false
  @moduletag :docker
  @moduletag timeout: 300_000

  alias Loopyard.{CanonicalRepo, VolumeManager, Docker}

  setup do
    ids = %{
      projA: uid(),
      projB: uid(),
      remote: uid(),
      ws1: uid(),
      ws2: uid(),
      wsA: uid(),
      wsB: uid(),
      wsC: uid()
    }

    on_exit(fn ->
      for id <- [ids.projA, ids.projB, ids.remote],
          do: VolumeManager.delete_volume(CanonicalRepo.volume_name(id))

      for id <- [ids.ws1, ids.ws2, ids.wsA, ids.wsB, ids.wsC],
          do: VolumeManager.delete_volume(VolumeManager.code_volume_name(id))
    end)

    {:ok, ids}
  end

  defp uid, do: "t" <> Integer.to_string(System.unique_integer([:positive]), 16)

  # An EMPTY bare repo (no seed commit) — simulates a fresh GitHub repo you push to.
  defp empty_bare(volume) do
    :ok = VolumeManager.create_volume(volume)

    Docker.docker(
      [
        "run",
        "--rm",
        "--entrypoint",
        "sh",
        "-v",
        "#{volume}:/r",
        "alpine/git:latest",
        "-c",
        "git init --bare --initial-branch=main /r"
      ],
      timeout: 60_000
    )
  end

  # Run git in a code volume — simulates the workspace agent doing work.
  defp git_in(volume, cmd) do
    Docker.docker(
      [
        "run",
        "--rm",
        "--entrypoint",
        "sh",
        "-v",
        "#{volume}:/workspace",
        "alpine/git:latest",
        "-c",
        "git config --global user.email a@a && git config --global user.name A && cd /workspace && #{cmd}"
      ],
      timeout: 120_000
    )
  end

  test "full v1 loop: init → fork → commit → integrate → fork-sees-it → push → clone-back", ids do
    # New blank project.
    assert {:ok, _canonA} = CanonicalRepo.init(ids.projA)

    # Fork a workspace off main.
    assert {:ok, ws1vol} = CanonicalRepo.fork(ids.projA, ids.ws1, "main", "feature")

    # Agent commits a file on the feature branch.
    assert {:ok, _} =
             git_in(
               ws1vol,
               "echo hello > greeting.txt && git add -A && git commit -m 'add greeting'"
             )

    # Integrate feature → canonical main (rebase + fast-forward).
    assert {:ok, _} = CanonicalRepo.integrate(ids.projA, ids.ws1, "feature")

    # A fresh fork off main now sees the file — proves canonical main got it.
    assert {:ok, ws2vol} = CanonicalRepo.fork(ids.projA, ids.ws2, "main", "verify")
    assert {:ok, out} = git_in(ws2vol, "cat greeting.txt")
    assert out =~ "hello"

    # Push canonical → a fresh empty "GitHub" bare remote, then clone it back as a new project.
    remote = CanonicalRepo.volume_name(ids.remote)
    assert {:ok, _} = empty_bare(remote)
    assert {:ok, _} = CanonicalRepo.push(ids.projA, {:volume, remote}, refspec: "main:main")

    assert {:ok, _canonB} = CanonicalRepo.init_from_remote(ids.projB, {:volume, remote})
    assert {:ok, wsBvol} = CanonicalRepo.fork(ids.projB, ids.wsB, "main", "fromclone")
    assert {:ok, out2} = git_in(wsBvol, "cat greeting.txt")
    assert out2 =~ "hello"
  end

  test "GitHub-host mode: fork repoints origin to the CLEAN url; integrate lands on the remote's main",
       ids do
    # A stand-in "GitHub": a bare repo seeded with the project's main.
    remote = CanonicalRepo.volume_name(ids.remote)
    assert {:ok, _} = CanonicalRepo.init(ids.projA)
    assert {:ok, _} = empty_bare(remote)
    assert {:ok, _} = CanonicalRepo.push(ids.projA, {:volume, remote}, refspec: "main:main")

    # Fork WITH a github_url → the workspace's origin is repointed to that clean
    # URL, and NO token is baked into .git/config (the whole point of 1a).
    github_url = "https://github.com/acme/widgets.git"
    assert {:ok, ws1vol} = CanonicalRepo.fork(ids.projA, ids.ws1, "main", "feature", github_url)

    assert {:ok, origin} = git_in(ws1vol, "git remote get-url origin")
    assert String.trim(origin) == github_url

    assert {:ok, cfg} = git_in(ws1vol, "cat .git/config")
    refute cfg =~ "@github.com", "no token may be persisted into .git/config"

    # Commit on feature, then integrate to the {:volume} "GitHub" remote's main.
    assert {:ok, _} = git_in(ws1vol, "echo hi > f.txt && git add -A && git commit -m feat")

    assert {:ok, _} =
             CanonicalRepo.integrate(ids.projA, ids.ws1, "feature", {:volume, remote})

    # The REMOTE's main now carries the feature commit — proves it landed on the
    # remote (not canonical). Clone it back and check.
    assert {:ok, _} = CanonicalRepo.init_from_remote(ids.projB, {:volume, remote})
    assert {:ok, wsBvol} = CanonicalRepo.fork(ids.projB, ids.wsB, "main", "check")
    assert {:ok, out} = git_in(wsBvol, "cat f.txt")
    assert out =~ "hi"
  end

  test "integrate fails cleanly on a rebase conflict (workspace left for the agent to resolve)",
       ids do
    assert {:ok, _} = CanonicalRepo.init(ids.projA)

    # Both branches forked off the SAME (initial) main.
    assert {:ok, wsAvol} = CanonicalRepo.fork(ids.projA, ids.wsA, "main", "a")
    assert {:ok, wsCvol} = CanonicalRepo.fork(ids.projA, ids.wsC, "main", "c")

    # A adds c.txt and integrates cleanly.
    assert {:ok, _} = git_in(wsAvol, "echo fromA > c.txt && git add -A && git commit -m A")
    assert {:ok, _} = CanonicalRepo.integrate(ids.projA, ids.wsA, "a")

    # C adds the SAME file with different content → rebase onto updated main conflicts.
    assert {:ok, _} = git_in(wsCvol, "echo fromC > c.txt && git add -A && git commit -m C")
    assert {:error, _} = CanonicalRepo.integrate(ids.projA, ids.wsC, "c")
  end
end
