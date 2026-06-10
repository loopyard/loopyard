defmodule Loopyard.OnboardingTest do
  @moduledoc """
  Smoke test for the v1 canonical-backed onboarding flow (#19) against REAL git +
  Docker volumes + the live registries. Codified from a live-instance validation.

      mix test --include docker test/loopyard/onboarding_test.exs
  """
  use ExUnit.Case, async: false
  @moduletag :docker
  @moduletag timeout: 300_000

  alias Loopyard.{Onboarding, CanonicalRepo, VolumeManager, WorkspaceRegistry, Docker}

  test "v1 loop: create project → code-ready main → fork → commit → integrate → fork sees it" do
    {:ok, project, main_ws} = Onboarding.create_project("smoke-#{uid()}")
    on_exit(fn -> cleanup(project) end)

    # The main workspace is registered, code-ready, and on `main`.
    assert main_ws.is_main
    assert WorkspaceRegistry.get_workspace(main_ws.id).setup.phase == :ready
    assert {:ok, branch} = git_in(main_ws.volume, "git branch --show-current")
    assert branch =~ "main"

    # The project is registered as canonical-backed.
    assert proj = Enum.find(Loopyard.ProjectRegistry.list_projects(), &(&1.id == project.id))
    assert proj.canonical

    # Fork a branch — isolated, code-ready, on its own branch.
    {:ok, ws} = Onboarding.fork(project.id, "main", "feature")
    assert {:ok, b} = git_in(ws.volume, "git branch --show-current")
    assert b =~ "feature"
    refute ws.is_main

    # Agent commits on the fork; integrate back into canonical main.
    assert {:ok, _} = git_in(ws.volume, "echo hi > f.txt && git add -A && git commit -m work")
    assert {:ok, _} = CanonicalRepo.integrate(project.id, ws.id, "feature")

    # A fresh fork off main now sees the merged file — the loop closed.
    {:ok, ws2} = Onboarding.fork(project.id, "main", "verify")
    assert {:ok, out} = git_in(ws2.volume, "cat f.txt")
    assert out =~ "hi"
  end

  defp uid, do: :crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)

  defp git_in(volume, cmd) do
    Docker.docker(
      [
        "run",
        "--rm",
        "--entrypoint",
        "sh",
        "-v",
        "#{volume}:/w",
        "alpine/git:latest",
        "-c",
        "git config --global user.email a@a && git config --global user.name A && cd /w && #{cmd}"
      ],
      timeout: 120_000
    )
  end

  # Generic cleanup — removes every workspace volume + ETS row for the project,
  # plus the canonical, regardless of how many forks the test made.
  defp cleanup(project) do
    for ws <- WorkspaceRegistry.list_workspaces(project.id) do
      VolumeManager.delete_volume(ws.volume)
      WorkspaceRegistry.delete(ws.id)
    end

    CanonicalRepo.remove(project.id)
    :ets.delete(:project_registry, project.id)
  end
end
