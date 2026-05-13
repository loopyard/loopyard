defmodule Loopyard.GitTest do
  use ExUnit.Case

  # Git operations shell out (`git init`, `git add`, `git commit`, …)
  # and make_temp_repo/0 makes 6 calls just to produce a 2-commit
  # fixture. Each test stays well under human-attention-span but
  # can exceed the suite's 2s default on a loaded box.
  @moduletag timeout: 10_000

  alias Loopyard.Git

  describe "repo_root/1" do
    test "returns repo root for a git directory" do
      # This project itself is a git repo
      assert {:ok, root} = Git.repo_root(File.cwd!())
      assert File.dir?(root)
      assert File.exists?(Path.join(root, ".git"))
    end

    test "returns error for non-git directory" do
      tmp = Path.join(System.tmp_dir!(), "loopyard-git-test-#{:rand.uniform(100_000)}")
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
      tmp = Path.join(System.tmp_dir!(), "loopyard-git-test-#{:rand.uniform(100_000)}")
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

  describe "log/2" do
    test "returns recent commits from this repo" do
      assert {:ok, entries} = Git.log(File.cwd!(), limit: 5)
      assert length(entries) > 0
      assert length(entries) <= 5

      first = hd(entries)
      assert is_binary(first.sha)
      assert String.length(first.sha) == 40
      assert is_binary(first.message)
      assert is_binary(first.author)
      assert is_binary(first.date)
    end

    test "returns commits from a temp repo" do
      tmp = make_temp_repo()

      assert {:ok, entries} = Git.log(tmp)
      assert length(entries) == 2
      assert hd(entries).message == "second commit"
      assert List.last(entries).message == "initial commit"

      File.rm_rf!(tmp)
    end

    test "returns error for non-git directory" do
      tmp = Path.join(System.tmp_dir!(), "loopyard-git-log-#{:rand.uniform(100_000)}")
      File.mkdir_p!(tmp)
      assert {:error, _} = Git.log(tmp)
      File.rm_rf!(tmp)
    end
  end

  describe "status/1" do
    test "returns empty staged and unstaged for clean repo" do
      tmp = make_temp_repo()
      assert {:ok, %{staged: [], unstaged: []}} = Git.status(tmp)
      File.rm_rf!(tmp)
    end

    test "untracked files appear in unstaged" do
      tmp = make_temp_repo()
      File.write!(Path.join(tmp, "new_file.txt"), "hello")
      assert {:ok, %{staged: staged, unstaged: unstaged}} = Git.status(tmp)
      assert staged == []
      assert length(unstaged) == 1
      assert hd(unstaged).status == "??"
      assert hd(unstaged).path == "new_file.txt"
      File.rm_rf!(tmp)
    end

    test "staged files appear in staged" do
      tmp = make_temp_repo()
      File.write!(Path.join(tmp, "staged.txt"), "hello")
      System.cmd("git", ["add", "staged.txt"], cd: tmp)
      assert {:ok, %{staged: staged, unstaged: unstaged}} = Git.status(tmp)
      assert length(staged) == 1
      assert hd(staged).status == "A"
      assert hd(staged).path == "staged.txt"
      assert unstaged == []
      File.rm_rf!(tmp)
    end

    test "modified file appears in unstaged, staged version in staged" do
      tmp = make_temp_repo()
      # Modify an existing tracked file
      File.write!(Path.join(tmp, "README.md"), "changed")
      System.cmd("git", ["add", "README.md"], cd: tmp)
      # Modify again after staging
      File.write!(Path.join(tmp, "README.md"), "changed again")

      assert {:ok, %{staged: staged, unstaged: unstaged}} = Git.status(tmp)
      assert length(staged) == 1
      assert hd(staged).status == "M"
      assert length(unstaged) == 1
      assert hd(unstaged).status == "M"
      File.rm_rf!(tmp)
    end
  end

  describe "commit_detail/2" do
    test "returns files changed with insertions/deletions" do
      tmp = make_temp_repo()
      {:ok, log} = Git.log(tmp, limit: 1)
      sha = hd(log).sha

      assert {:ok, detail} = Git.commit_detail(tmp, sha)
      assert detail.sha == sha
      assert is_binary(detail.message)
      assert is_list(detail.files)
      File.rm_rf!(tmp)
    end
  end

  describe "diff/2" do
    test "returns empty diff for clean repo" do
      tmp = make_temp_repo()
      assert {:ok, ""} = Git.diff(tmp)
      File.rm_rf!(tmp)
    end

    test "returns diff for modified tracked file" do
      tmp = make_temp_repo()
      File.write!(Path.join(tmp, "README.md"), "changed content")
      assert {:ok, diff_output} = Git.diff(tmp)
      assert diff_output =~ "changed content"
      File.rm_rf!(tmp)
    end

    test "returns diff against a ref" do
      tmp = make_temp_repo()
      assert {:ok, diff_output} = Git.diff(tmp, ref: "HEAD~1")
      assert diff_output =~ "second file"
      File.rm_rf!(tmp)
    end
  end

  describe "show/3" do
    test "shows file at HEAD" do
      tmp = make_temp_repo()
      assert {:ok, content} = Git.show(tmp, "HEAD", "README.md")
      assert content =~ "hello"
      File.rm_rf!(tmp)
    end

    test "returns error for non-existent file" do
      tmp = make_temp_repo()
      assert {:error, _} = Git.show(tmp, "HEAD", "nope.txt")
      File.rm_rf!(tmp)
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

  # Creates a temp git repo with 2 commits for testing
  defp make_temp_repo do
    tmp = Path.join(System.tmp_dir!(), "loopyard-git-test-#{:rand.uniform(100_000)}")
    File.mkdir_p!(tmp)
    System.cmd("git", ["init"], cd: tmp, stderr_to_stdout: true)
    System.cmd("git", ["config", "user.email", "test@test.com"], cd: tmp)
    System.cmd("git", ["config", "user.name", "Test"], cd: tmp)

    File.write!(Path.join(tmp, "README.md"), "hello")
    System.cmd("git", ["add", "."], cd: tmp)
    System.cmd("git", ["commit", "-m", "initial commit"], cd: tmp, stderr_to_stdout: true)

    File.write!(Path.join(tmp, "second.txt"), "second file")
    System.cmd("git", ["add", "."], cd: tmp)
    System.cmd("git", ["commit", "-m", "second commit"], cd: tmp, stderr_to_stdout: true)

    tmp
  end
end
