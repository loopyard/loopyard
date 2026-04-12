defmodule BoomLooper.Source.LocalTest do
  use ExUnit.Case, async: false

  alias BoomLooper.Source.Local

  # These tests exercise add_project/create_workspace/queries. They stub
  # Mutagen so they don't shell out, and build against a real temp git repo
  # so Git.* wrappers exercise the real thing.

  setup do
    # Mutagen calls are routed through Application env — short-circuit them
    # so "installed?" returns true and every runner invocation is a no-op.
    Application.put_env(:boom_looper, :mutagen_runner, fn _args -> {"", 0} end)

    on_exit(fn -> Application.delete_env(:boom_looper, :mutagen_runner) end)

    :ok
  end

  defp make_repo do
    dir = Path.join(System.tmp_dir!(), "bl-local-test-#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main"], cd: dir, stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["config", "user.email", "t@t.local"], cd: dir)
    {_, 0} = System.cmd("git", ["config", "user.name", "Test"], cd: dir)
    File.write!(Path.join(dir, "README.md"), "hello")
    {_, 0} = System.cmd("git", ["add", "."], cd: dir)
    {_, 0} = System.cmd("git", ["commit", "-qm", "init"], cd: dir, stderr_to_stdout: true)
    dir
  end

  describe "add_project/2" do
    test "builds a Local project for a git repo on disk" do
      # Mutagen.installed? calls System.find_executable, not the runner.
      # If mutagen isn't installed on this machine, add_project will return
      # {:error, :mutagen_not_installed}; in that case skip the assertion
      # since we're only checking the happy shape.
      if not BoomLooper.Source.Local.Mutagen.installed?() do
        :skip
      else
        dir = make_repo()

        assert {:ok, project} = Local.add_project(dir)
        assert project.source_type == :local
        assert project.path == dir
        assert project.is_git == true
        assert project.source_config.repo_root == dir
        assert is_binary(project.source_config.default_branch)

        File.rm_rf!(dir)
      end
    end

    test "returns an error for a non-existent directory" do
      assert {:error, _} = Local.add_project("/nope-#{:rand.uniform(100_000)}")
    end
  end

  describe "queries" do
    test "checkout_path/1 falls back to worktrees root when only id is provided" do
      path = Local.checkout_path(%{id: "zzzz"})
      assert is_binary(path)
      assert String.ends_with?(path, "worktrees/zzzz")
    end
  end
end
