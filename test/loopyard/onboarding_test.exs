defmodule Loopyard.OnboardingTest do
  @moduledoc """
  Smoke test for the v1 canonical-backed onboarding flow (#19) against REAL git +
  Docker volumes + the live registries. Codified from a live-instance validation.

      mix test --include docker test/loopyard/onboarding_test.exs
  """
  use ExUnit.Case, async: false
  @moduletag :docker
  @moduletag timeout: 300_000

  alias Loopyard.{
    Onboarding,
    Workflow,
    CanonicalRepo,
    CanonicalStore,
    VolumeManager,
    VolumeIO,
    WorkspaceRegistry,
    Docker
  }

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

  test "fork_from_workspace copies the LIVE workspace: uncommitted edits + .loopyard infra" do
    {:ok, project, main_ws} = Onboarding.create_project("livefork-#{uid()}")
    on_exit(fn -> cleanup(project) end)

    # The agent has UNCOMMITTED work-in-progress + gitignored infra in its volume.
    :ok = VolumeIO.write_file(main_ws.volume, "wip.txt", "in progress\n")

    :ok =
      VolumeIO.write_file(
        main_ws.volume,
        ".loopyard/workspace/docker-compose.yml",
        ~s(services:\n  web:\n    image: nginx:alpine\n)
      )

    # "Branch THIS and try something else" — fork the live workspace.
    {:ok, fork} = Onboarding.fork_from_workspace(project.id, main_ws.id, "experiment")

    # New branch, its own volume.
    assert {:ok, b} = git_in(fork.volume, "git branch --show-current")
    assert b =~ "experiment"
    refute fork.volume == main_ws.volume

    # The in-progress file came along (it was never committed).
    assert {:ok, wip} = git_in(fork.volume, "cat wip.txt")
    assert wip =~ "in progress"

    # The gitignored .loopyard infra came along too — so the fork boots ready.
    assert {:ok, compose} = git_in(fork.volume, "cat .loopyard/workspace/docker-compose.yml")
    assert compose =~ "nginx:alpine"
  end

  test "working is the default: start_working boots a cheap agent container, no compose cluster" do
    {:ok, project, ws} = Onboarding.create_project("working-#{uid()}")

    on_exit(fn ->
      Onboarding.stop_working(ws.id)
      cleanup(project)
    end)

    # Fresh workspace: code-ready, but nothing is "working" yet.
    refute Loopyard.Workspace.working?(ws.id)

    # Start working — cheap, no preview cluster, no agent-written compose needed.
    assert {:ok, container} = Onboarding.start_working(ws.id)
    assert container == "loopyard-#{ws.id}-work"
    assert Loopyard.Workspace.working?(ws.id)

    # The preview cluster is a *separate* concern and is NOT running.
    refute Loopyard.Workspace.container_running?(ws.id)
    assert WorkspaceRegistry.get_workspace(ws.id).status == :stopped

    # The agent's exec target resolves to the work container.
    assert {:ok, ^container} = Loopyard.Workspace.agent_container(ws.id)

    # And the canonical main code is actually there (git-populated volume).
    assert {:ok, out} =
             Loopyard.Workspace.WorkContainer.exec(ws.id, "ls -a /workspace")

    assert out =~ ".git"

    # Stop working releases the container; code volume untouched.
    :ok = Onboarding.stop_working(ws.id)
    refute Loopyard.Workspace.working?(ws.id)
  end

  test "git works in the work container against the canonical workspace's .git (commit lands)" do
    {:ok, project, ws} = Onboarding.create_project("git-#{uid()}")

    on_exit(fn ->
      Loopyard.Workspace.WorkContainer.down(ws.id)
      cleanup(project)
    end)

    alias Loopyard.Workspace.WorkContainer
    {:ok, _} = WorkContainer.ensure_up(ws.id)

    setup_git =
      "git config --global --add safe.directory /workspace; " <>
        "git config --global user.email a@a; git config --global user.name A"

    # The canonical checkout seeded an initial commit on main — the agent can read it.
    assert {:ok, log} = WorkContainer.exec(ws.id, "#{setup_git}; git -C /workspace log --oneline")
    assert log =~ ~r/\w+/

    # The agent can commit new work — which is what makes merge-back meaningful.
    assert {:ok, _} = WorkContainer.exec(ws.id, "echo 'agent change' > /workspace/feature.txt")

    assert {:ok, _} =
             WorkContainer.exec(
               ws.id,
               "#{setup_git}; git -C /workspace add -A && git -C /workspace commit -m 'agent work'"
             )

    assert {:ok, log2} = WorkContainer.exec(ws.id, "git -C /workspace log --oneline")
    assert log2 =~ "agent work"
  end

  test "preview env opt-in: code-ready workspace + compose → a real running container" do
    {:ok, project, ws} = Onboarding.create_project("preview-#{uid()}")

    on_exit(fn ->
      Onboarding.stop_preview(ws.id)
      cleanup(project)
    end)

    # The agent writes a minimal compose into the volume.
    :ok =
      VolumeIO.write_file(
        ws.volume,
        ".loopyard/workspace/docker-compose.yml",
        ~s(services:\n  web:\n    image: nginx:alpine\n    ports:\n      - "80"\n)
      )

    # Opt-in: bring up the preview env.
    assert {:ok, _} = Onboarding.start_preview(ws.id)
    assert WorkspaceRegistry.get_workspace(ws.id).status == :running

    # A real container is up for this workspace.
    assert {:ok, out} =
             Docker.docker([
               "ps",
               "--filter",
               "name=loopyard-#{ws.id}",
               "--format",
               "{{.Names}} {{.Status}}"
             ])

    assert out =~ "loopyard-#{ws.id}-web-1"
    assert out =~ "Up"
  end

  test "persistence: canonical project + workspaces survive a restore (simulated restart)" do
    {:ok, project, _main} = Onboarding.create_project("persist-#{uid()}")
    {:ok, _ws} = Onboarding.fork(project.id, "main", "branchx")
    on_exit(fn -> cleanup(project) end)

    # Persisted to disk.
    assert Map.has_key?(CanonicalStore.load(), project.id)

    # Simulate a restart: drop this project's ETS rows.
    for w <- WorkspaceRegistry.list_workspaces(project.id), do: WorkspaceRegistry.delete(w.id)
    :ets.delete(:project_registry, project.id)
    assert WorkspaceRegistry.list_workspaces(project.id) == []
    refute Enum.find(Loopyard.ProjectRegistry.list_projects(), &(&1.id == project.id))

    # Restore from disk re-registers the project + both workspaces (volumes persist).
    Onboarding.restore()

    assert Enum.find(Loopyard.ProjectRegistry.list_projects(), &(&1.id == project.id))

    names =
      WorkspaceRegistry.list_workspaces(project.id) |> Enum.map(& &1.name) |> Enum.sort()

    assert names == ["branchx", "main"]
  end

  test "github sync wiring: attach a remote (persisted) + sync pushes canonical main to it" do
    {:ok, project, _main} = Onboarding.create_project("sync-#{uid()}")
    remote_vol = "loopyard-tmpremote-#{uid()}-canonical"

    on_exit(fn ->
      cleanup(project)
      VolumeManager.delete_volume(remote_vol)
    end)

    # Attach + persist a (string) remote — the "hook up GitHub later" move.
    :ok = Onboarding.attach_remote(project.id, "git@github.com:acme/repo.git")

    assert Loopyard.ProjectRegistry.get_project(project.id).source_config.remote ==
             "git@github.com:acme/repo.git"

    assert CanonicalStore.load()[project.id]["remote"] == "git@github.com:acme/repo.git"

    # Sync to a local empty bare remote (override) — proves canonical main is pushed.
    assert {:ok, _} = empty_bare(remote_vol)
    assert {:ok, _} = Onboarding.sync(project.id, remote: {:volume, remote_vol})

    assert {:ok, out} =
             Docker.docker([
               "run",
               "--rm",
               "--entrypoint",
               "sh",
               "-v",
               "#{remote_vol}:/r",
               "alpine/git:latest",
               "-c",
               "cd /r && git branch"
             ])

    assert out =~ "main"
  end

  test "workflow fork is confirmation-gated: deny blocks, approve runs, action reaches the policy" do
    {:ok, project, _main} = Onboarding.create_project("wf-#{uid()}")
    on_exit(fn -> cleanup(project) end)

    before = length(WorkspaceRegistry.list_workspaces(project.id))

    # Deny → nothing created (the agent-spawns-workspaces guardrail).
    assert {:error, :denied} =
             Workflow.fork(project.id, "main", "nope", confirm: fn _action -> :deny end)

    assert length(WorkspaceRegistry.list_workspaces(project.id)) == before

    # Default (:auto) → approved, workspace created.
    assert {:ok, ws} = Workflow.fork(project.id, "main", "yes")
    assert ws.name == "yes"

    # The action map (what the UI card renders) is handed to the policy.
    me = self()

    assert {:ok, _} =
             Workflow.fork(project.id, "main", "carded",
               confirm: fn action ->
                 send(me, {:card, action})
                 :approve
               end
             )

    assert_received {:card, %{verb: :fork, branch: "carded", project_id: _}}
  end

  defp uid, do: :crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)

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
    CanonicalStore.delete(project.id)
  end
end
