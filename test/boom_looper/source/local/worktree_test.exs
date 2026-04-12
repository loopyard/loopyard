defmodule BoomLooper.Source.Local.WorktreeTest do
  use ExUnit.Case

  alias BoomLooper.Source.Local.Worktree

  describe "path_for/1" do
    test "builds an absolute path under BOOMLOOPER_HOME/worktrees" do
      path = Worktree.path_for("abcd")
      assert Path.type(path) == :absolute
      assert String.ends_with?(path, "worktrees/abcd")
    end
  end

  describe "root/0" do
    test "ends with /worktrees" do
      assert String.ends_with?(Worktree.root(), "/worktrees")
    end
  end

  describe "create/3 + remove/1 (:worktree tag — needs real git)" do
    @tag :worktree
    test "creates a branch worktree under BOOMLOOPER_HOME/worktrees, then removes it" do
      repo = File.cwd!()
      ws_id = "wt-#{:rand.uniform(100_000)}"
      branch = "bl-test-#{:rand.uniform(100_000)}"

      try do
        assert {:ok, wt_path} = Worktree.create(repo, ws_id, branch)
        assert wt_path == Worktree.path_for(ws_id)
        assert File.dir?(wt_path)
        assert File.exists?(Path.join(wt_path, ".git"))
      after
        Worktree.remove(ws_id)
        System.cmd("git", ["branch", "-D", branch], cd: repo, stderr_to_stdout: true)
      end
    end
  end
end
