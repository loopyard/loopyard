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

  @doc """
  Get recent commit log. Returns {:ok, list} where each entry is
  %{sha, message, author, date}.

  Options:
    - :limit — max number of commits (default 20)
  """
  def log(path, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    case git(["log", "--oneline", "--format=%H\t%s\t%an\t%aI", "-#{limit}"], cd: path) do
      {:ok, output} ->
        entries =
          output
          |> String.trim()
          |> String.split("\n", trim: true)
          |> Enum.map(fn line ->
            case String.split(line, "\t", parts: 4) do
              [sha, message, author, date] ->
                %{sha: sha, message: message, author: author, date: date}

              _ ->
                nil
            end
          end)
          |> Enum.reject(&is_nil/1)

        {:ok, entries}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Get working tree status (porcelain format).
  Returns {:ok, list} where each entry is %{status, path}.
  """
  def status(path) do
    case git(["status", "--porcelain"], cd: path) do
      {:ok, output} ->
        entries =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(fn line ->
            status_code = String.slice(line, 0, 2) |> String.trim()
            file_path = String.slice(line, 3..-1//1)
            %{status: status_code, path: file_path}
          end)

        {:ok, entries}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Get diff output.

  Options:
    - :ref — compare against a specific ref (e.g. "HEAD~1")
    - :file — limit diff to a specific file
  """
  def diff(path, opts \\ []) do
    ref = Keyword.get(opts, :ref)
    file = Keyword.get(opts, :file)

    args =
      ["diff"] ++
        if(ref, do: [ref], else: []) ++
        if(file, do: ["--", file], else: [])

    git(args, cd: path)
  end

  @doc """
  Show file contents at a specific ref.
  Returns {:ok, content} or {:error, reason}.
  """
  def show(path, ref, file) do
    git(["show", "#{ref}:#{file}"], cd: path)
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
