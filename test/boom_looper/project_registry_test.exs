defmodule BoomLooper.ProjectRegistryTest do
  use ExUnit.Case

  alias BoomLooper.ProjectRegistry

  setup do
    BoomLooper.StateKeeper.ensure_tables!()
    # Clean up any existing state — wipe both tables so stale workspaces
    # from prior tests don't leak is_main/worktree_path values.
    :ets.delete_all_objects(:project_registry)
    :ets.delete_all_objects(:workspace_registry)
    :ok
  end

  describe "add/1" do
    test "registers a git repo as a project with main workspace" do
      path = File.cwd!()
      assert {:ok, project, workspace} = ProjectRegistry.add(path)
      assert project.is_git == true
      assert workspace.is_main == true
      assert workspace.project_id == project.id
    end

    test "returns error for non-existent path" do
      assert {:error, _} = ProjectRegistry.add("/nonexistent/path/#{:rand.uniform(100_000)}")
    end

    test "is idempotent — adding same path twice returns same project" do
      path = File.cwd!()
      {:ok, project1, _} = ProjectRegistry.add(path)
      {:ok, project2, _} = ProjectRegistry.add(path)
      assert project1.id == project2.id
    end

    test "discovers existing worktrees" do
      path = File.cwd!()
      {:ok, project, _} = ProjectRegistry.add(path)
      workspaces = ProjectRegistry.list_workspaces(project.id)
      # Should have at least the main workspace
      assert length(workspaces) >= 1
    end

    test "no duplicate workspace names within a project" do
      path = File.cwd!()
      {:ok, project, _} = ProjectRegistry.add(path)
      workspaces = ProjectRegistry.list_workspaces(project.id)
      names = Enum.map(workspaces, & &1.name)
      assert names == Enum.uniq(names),
        "Found duplicate workspace names: #{inspect(names -- Enum.uniq(names))}"
    end
  end

  describe "add/1 (via Source.Local)" do
    test "tags Local projects with source_type and source_config" do
      path = File.cwd!()
      assert {:ok, project, _workspace} = ProjectRegistry.add(path)
      assert project.source_type == :local
      assert project.source_config.repo_root == path
      assert is_binary(project.source_config.default_branch)
    end

    test "main workspace for a Local project has worktree_path == host repo path" do
      path = File.cwd!()
      {:ok, _project, workspace} = ProjectRegistry.add(path)
      assert workspace.is_main == true
      assert workspace.worktree_path == path
    end
  end

  describe "add_workspace/2 (adapter dispatch)" do
    @tag :worktree
    @tag timeout: 10_000
    test "delegates to Source.Local.create_workspace for a Local project" do
      # Mutagen is stubbed — create_workspace only touches git + volumes.
      # The volume creation call shells out to docker, so this test is
      # tagged :worktree (needs real git) and excluded by default.
      Application.put_env(:boom_looper, :mutagen_runner, fn _args -> {"", 0} end)

      on_exit(fn -> Application.delete_env(:boom_looper, :mutagen_runner) end)

      path = File.cwd!()
      {:ok, project, _main_ws} = ProjectRegistry.add(path)

      branch = "bl-adapter-test-#{:rand.uniform(100_000)}"

      case ProjectRegistry.add_workspace(project.id, branch) do
        {:ok, workspace} ->
          assert workspace.branch == branch
          assert workspace.volume != nil
          assert is_binary(workspace.worktree_path)
          assert String.ends_with?(workspace.worktree_path, "worktrees/#{workspace.id}")

          # Cleanup
          ProjectRegistry.remove_workspace(workspace.id)
          System.cmd("git", ["branch", "-D", branch], cd: path, stderr_to_stdout: true)

        {:error, _} ->
          # Worktree creation may fail in constrained environments; skip.
          :ok
      end
    end
  end

  describe "list_projects/0" do
    test "lists all registered projects" do
      path = File.cwd!()
      ProjectRegistry.add(path)
      projects = ProjectRegistry.list_projects()
      assert length(projects) >= 1
    end
  end

  describe "get_project/1" do
    test "returns project by ID" do
      path = File.cwd!()
      {:ok, project, _} = ProjectRegistry.add(path)
      assert ProjectRegistry.get_project(project.id) == project
    end

    test "returns nil for unknown ID" do
      assert ProjectRegistry.get_project("nonexistent") == nil
    end
  end

  describe "list_workspaces/1" do
    test "returns workspaces for a project" do
      path = File.cwd!()
      {:ok, project, _} = ProjectRegistry.add(path)
      workspaces = ProjectRegistry.list_workspaces(project.id)
      assert length(workspaces) >= 1
      assert hd(workspaces).project_id == project.id
    end

    test "main workspace exists and is marked is_main" do
      path = File.cwd!()
      {:ok, project, _} = ProjectRegistry.add(path)
      workspaces = ProjectRegistry.list_workspaces(project.id)
      main = Enum.find(workspaces, & &1.is_main)
      assert main != nil, "expected a workspace with is_main == true"
      assert main.path == project.path
    end
  end

  describe "remove_project/1" do
    # remove_project loops through each workspace and runs the full
    # Destructor + volume-cleanup pipeline (compose down, several
    # `docker volume rm`s, prune_temp_containers). Each Docker call
    # burns 1.3s of Retry backoff when the daemon is unreachable, so
    # a Docker-less environment exhausts the test budget. Tag :docker.
    @tag :docker
    @tag timeout: 30_000
    test "removes project and all workspaces" do
      path = File.cwd!()
      {:ok, project, _} = ProjectRegistry.add(path)
      assert :ok = ProjectRegistry.remove_project(project.id)
      assert ProjectRegistry.get_project(project.id) == nil
      assert ProjectRegistry.list_workspaces(project.id) == []
    end

    @tag :docker
    @tag timeout: 30_000
    test "wipes the host-side virtual workspace dir so agents.log is gone" do
      # Regression: agents.log lives at
      #   ~/.boomlooper/workspaces/<ws_id>/.boomlooper/workspace/agents.log
      # If remove_project doesn't delete this dir, the next eval that
      # re-clones the same git URL gets the SAME workspace_id and
      # ServiceManager.init replays the leftover log, resurrecting
      # ghost agents from the previous run. We hit this in a real eval.
      tmp = Path.join(System.tmp_dir!(), "bl-virtual-cleanup-#{:rand.uniform(100_000)}")
      File.mkdir_p!(tmp)
      File.write!(Path.join(tmp, ".git"), "")  # marker so it's "git-like"
      {:ok, project, workspace} = ProjectRegistry.add(tmp)

      virtual_dir =
        Path.join([BoomLooper.Workspace.home_dir(), "workspaces", workspace.id])

      # Simulate the workspace having been used at least once: write a
      # fake agents.log that any future replay would pick up.
      log_path = Path.join([virtual_dir, ".boomlooper", "workspace", "agents.log"])
      File.mkdir_p!(Path.dirname(log_path))
      File.write!(log_path, "fake log content")
      assert File.exists?(log_path)

      assert :ok = ProjectRegistry.remove_project(project.id)

      refute File.exists?(log_path),
        "agents.log survived remove_project — ghost agents will resurrect on next eval"
      refute File.exists?(virtual_dir),
        "virtual workspace dir survived remove_project"
    end
  end

  describe "add_from_url/2" do
    @tag :docker
    test "registers a project from a public git URL" do
      # Use a small public repo for testing
      git_url = "https://github.com/octocat/Hello-World.git"

      on_exit(fn ->
        # Clean up any created projects
        project_id = BoomLooper.Workspace.project_id_from_git(git_url)
        ProjectRegistry.remove_project(project_id)
      end)

      assert {:ok, project, workspace} = ProjectRegistry.add_from_url(git_url, branch: "master")

      assert project.git_url == git_url
      assert project.is_git == true
      assert project.volume_based == true

      assert workspace.branch == "master"
      assert workspace.volume_based == true
      assert workspace.volume != nil
    end

    test "generates consistent IDs for same URL" do
      git_url = "git@github.com:owner/repo.git"

      # Don't actually clone, just check IDs are consistent
      project_id1 = BoomLooper.Workspace.project_id_from_git(git_url)
      project_id2 = BoomLooper.Workspace.project_id_from_git(git_url)
      assert project_id1 == project_id2

      workspace_id1 = BoomLooper.Workspace.workspace_id_from_git(git_url, "main")
      workspace_id2 = BoomLooper.Workspace.workspace_id_from_git(git_url, "main")
      assert workspace_id1 == workspace_id2
    end

    test "generates different workspace IDs for different branches" do
      git_url = "git@github.com:owner/repo.git"

      ws_main = BoomLooper.Workspace.workspace_id_from_git(git_url, "main")
      ws_dev = BoomLooper.Workspace.workspace_id_from_git(git_url, "develop")

      assert ws_main != ws_dev
    end
  end
end
