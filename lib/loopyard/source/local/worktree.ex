defmodule Loopyard.Source.Local.Worktree do
  @moduledoc """
  Host-side git worktree management for Local workspaces.

  Each Local workspace owns a git worktree under
  `~/.loopyard/worktrees/<workspace_id>`. The human uses this path from
  their own terminal (commit, push, pull, merge); Mutagen keeps the
  workspace volume in sync with it.
  """

  alias Loopyard.{Git, Workspace}

  @doc "Base directory that holds every Local worktree."
  def root do
    Path.join(Workspace.home_dir(), "worktrees")
  end

  @doc "Absolute worktree path for a given workspace id."
  def path_for(workspace_id) when is_binary(workspace_id) do
    Path.join(root(), workspace_id)
  end

  @doc """
  Create a new worktree for `branch` off the project's repo. Returns the
  absolute path of the worktree. If `branch` already exists on the repo it
  is checked out; otherwise it is created off the current HEAD.
  """
  def create(repo_path, workspace_id, branch) when is_binary(branch) do
    wt_path = path_for(workspace_id)
    File.mkdir_p!(root())

    case Git.worktree_add(repo_path, branch, path: wt_path) do
      {:ok, ^wt_path} -> {:ok, wt_path}
      {:ok, other} -> {:ok, other}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Remove the worktree for a workspace. Best-effort — returns `:ok` even if
  the worktree was never created, since callers use this on teardown.
  """
  def remove(workspace_id) do
    wt_path = path_for(workspace_id)

    if File.dir?(wt_path) do
      Git.worktree_remove(wt_path)
    end

    # Belt and suspenders: if git didn't clean it, nuke the directory.
    File.rm_rf(wt_path)
    :ok
  end

  @doc "Current HEAD short sha for the worktree."
  def current_revision(workspace_id) do
    wt_path = path_for(workspace_id)

    case System.cmd("git", ["rev-parse", "--short", "HEAD"],
           cd: wt_path,
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, _} -> {:error, String.trim(output)}
    end
  rescue
    ErlangError -> {:error, :worktree_missing}
  end

  @doc "Does the worktree have uncommitted changes?"
  def dirty?(workspace_id) do
    wt_path = path_for(workspace_id)

    case System.cmd("git", ["status", "--porcelain"],
           cd: wt_path,
           stderr_to_stdout: true
         ) do
      {"", 0} -> false
      {_output, 0} -> true
      _ -> false
    end
  rescue
    ErlangError -> false
  end
end
