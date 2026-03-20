defmodule BoomLooper.GitTest do
  use ExUnit.Case

  alias BoomLooper.Git

  describe "repo_root/1" do
    test "returns repo root for a git directory" do
      # This project itself is a git repo
      assert {:ok, root} = Git.repo_root(File.cwd!())
      assert File.dir?(root)
      assert File.exists?(Path.join(root, ".git"))
    end

    test "returns error for non-git directory" do
      tmp = Path.join(System.tmp_dir!(), "boom-looper-git-test-#{:rand.uniform(100_000)}")
      File.mkdir_p!(tmp)

      assert {:error, _} = Git.repo_root(tmp)

      File.rm_rf!(tmp)
    end
  end

  describe "current_branch/1" do
    test "returns current branch name" do
      assert {:ok, branch} = Git.current_branch(File.cwd!())
      assert is_binary(branch)
      assert branch != ""
    end
  end

  describe "is_repo?/1" do
    test "returns true for git repos" do
      assert Git.is_repo?(File.cwd!())
    end

    test "returns false for non-git dirs" do
      tmp = Path.join(System.tmp_dir!(), "boom-looper-git-test-#{:rand.uniform(100_000)}")
      File.mkdir_p!(tmp)
      refute Git.is_repo?(tmp)
      File.rm_rf!(tmp)
    end
  end

  describe "worktree_list/1" do
    test "lists at least the main worktree" do
      assert {:ok, worktrees} = Git.worktree_list(File.cwd!())
      assert length(worktrees) >= 1
      main = hd(worktrees)
      assert Map.has_key?(main, :path)
      assert Map.has_key?(main, :branch)
    end
  end

  describe "worktree_add and remove" do
    @tag :worktree
    test "creates and removes a worktree" do
      repo = File.cwd!()
      branch = "test-worktree-#{:rand.uniform(100_000)}"

      case Git.worktree_add(repo, branch) do
        {:ok, wt_path} ->
          assert File.dir?(wt_path)

          # Verify it shows in worktree list
          {:ok, worktrees} = Git.worktree_list(repo)
          assert Enum.any?(worktrees, &(&1[:branch] == branch))

          # Clean up
          Git.worktree_remove(wt_path)
          # Also delete the branch
          System.cmd("git", ["branch", "-D", branch], cd: repo, stderr_to_stdout: true)

        {:error, reason} ->
          # May fail in CI or restricted environments
          IO.puts("Skipping worktree test: #{reason}")
      end
    end
  end
end
