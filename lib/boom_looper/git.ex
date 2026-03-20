defmodule BoomLooper.Git do
  @moduledoc """
  Thin wrapper around git CLI for repo and worktree operations.
  """

  @doc "Get the git repo root for a path. Returns {:ok, path} or {:error, reason}."
  def repo_root(path) do
    case git(["rev-parse", "--show-toplevel"], cd: path) do
      {:ok, root} -> {:ok, String.trim(root)}
      {:error, _} -> {:error, "Not a git repository: #{path}"}
    end
  end

  @doc "Get the current branch name. Returns {:ok, name} or {:error, reason}."
  def current_branch(path) do
    case git(["branch", "--show-current"], cd: path) do
      {:ok, ""} ->
        # Detached HEAD — try to get a useful name
        case git(["rev-parse", "--short", "HEAD"], cd: path) do
          {:ok, sha} -> {:ok, "detached-#{String.trim(sha)}"}
          {:error, _} -> {:error, "Could not determine branch"}
        end

      {:ok, branch} ->
        {:ok, String.trim(branch)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Check if a path is inside a git repository."
  def is_repo?(path) do
    match?({:ok, _}, repo_root(path))
  end

  @doc "List all worktrees for a repo. Returns list of %{path: ..., branch: ..., head: ...}."
  def worktree_list(repo_path) do
    case git(["worktree", "list", "--porcelain"], cd: repo_path) do
      {:ok, output} -> {:ok, parse_worktree_list(output)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Add a new worktree for a branch. Creates branch if it doesn't exist."
  def worktree_add(repo_path, branch_name, opts \\ []) do
    worktree_dir = Keyword.get(opts, :path, worktree_path(repo_path, branch_name))
    File.mkdir_p!(Path.dirname(worktree_dir))

    # Try to add existing branch first, fall back to creating new
    case git(["worktree", "add", worktree_dir, branch_name], cd: repo_path) do
      {:ok, _} ->
        {:ok, worktree_dir}

      {:error, _} ->
        # Branch doesn't exist — create from HEAD
        case git(["worktree", "add", "-b", branch_name, worktree_dir], cd: repo_path) do
          {:ok, _} -> {:ok, worktree_dir}
          {:error, reason} -> {:error, "Failed to create worktree: #{reason}"}
        end
    end
  end

  @doc "Remove a worktree."
  def worktree_remove(worktree_path) do
    case git(["worktree", "remove", "--force", worktree_path]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, "Failed to remove worktree: #{reason}"}
    end
  end

  @doc "List remote branches."
  def remote_branches(repo_path) do
    case git(["branch", "-r", "--format", "%(refname:short)"], cd: repo_path) do
      {:ok, output} ->
        branches = output
          |> String.split("\n", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&String.starts_with?(&1, "origin/HEAD"))
          |> Enum.map(&String.replace_prefix(&1, "origin/", ""))
        {:ok, branches}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Get the default worktree path for a branch."
  def worktree_path(repo_path, branch_name) do
    Path.join([repo_path, ".worktrees", branch_name])
  end

  # --- Private ---

  defp git(args, opts \\ []) do
    cd = Keyword.get(opts, :cd)
    cmd_opts = [stderr_to_stdout: true]
    cmd_opts = if cd, do: Keyword.put(cmd_opts, :cd, cd), else: cmd_opts

    case System.cmd("git", args, cmd_opts) do
      {output, 0} -> {:ok, output}
      {output, _} -> {:error, String.trim(output)}
    end
  end

  defp parse_worktree_list(output) do
    output
    |> String.split("\n\n", trim: true)
    |> Enum.map(fn block ->
      lines = String.split(block, "\n", trim: true)
      Enum.reduce(lines, %{}, fn line, acc ->
        cond do
          String.starts_with?(line, "worktree ") -> Map.put(acc, :path, String.trim_leading(line, "worktree "))
          String.starts_with?(line, "HEAD ") -> Map.put(acc, :head, String.trim_leading(line, "HEAD "))
          String.starts_with?(line, "branch ") -> Map.put(acc, :branch, String.trim_leading(line, "branch refs/heads/"))
          line == "bare" -> Map.put(acc, :bare, true)
          line == "detached" -> Map.put(acc, :detached, true)
          true -> acc
        end
      end)
    end)
    |> Enum.reject(&Map.has_key?(&1, :bare))
  end
end
