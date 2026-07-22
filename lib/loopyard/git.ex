defmodule Loopyard.Git do
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

  @doc """
  Remove a worktree.

  `git worktree remove` must run inside the OWNING repo — otherwise git
  resolves it against the cwd's repo (under `mix loopyard.server`, that's the
  Loopyard repo), fails with "is not a working tree", and leaves stale
  registration in `.git/worktrees/` that blocks re-adding the same branch.

  Pass `repo_path` when the caller knows it. If omitted, we derive the owning
  repo from the worktree's own git metadata (works while the dir still
  exists). Always follows with `git worktree prune` so a previously-orphaned
  registration (dir already `rm_rf`'d) is cleared too.
  """
  def worktree_remove(worktree_path, repo_path \\ nil) do
    repo = repo_path || owning_repo(worktree_path)

    result =
      if repo do
        case git(["worktree", "remove", "--force", worktree_path], cd: repo) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, "Failed to remove worktree: #{reason}"}
        end
      else
        # No repo context available (dir gone, no repo_path). Best-effort.
        case git(["worktree", "remove", "--force", worktree_path]) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, "Failed to remove worktree: #{reason}"}
        end
      end

    if repo, do: worktree_prune(repo)
    result
  end

  @doc "Prune stale worktree administrative entries in `repo_path`."
  def worktree_prune(repo_path) do
    case git(["worktree", "prune"], cd: repo_path) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Derive the owning repo of a linked worktree from its own git metadata.
  # `--git-common-dir` points at the main repo's `.git`; its parent is the repo.
  defp owning_repo(worktree_path) do
    case git(["rev-parse", "--path-format=absolute", "--git-common-dir"], cd: worktree_path) do
      {:ok, output} ->
        common_dir = output |> String.trim() |> Path.expand()
        if common_dir == "", do: nil, else: Path.dirname(common_dir)

      {:error, _} ->
        nil
    end
  end

  @doc "List remote branches."
  def remote_branches(repo_path) do
    case git(["branch", "-r", "--format", "%(refname:short)"], cd: repo_path) do
      {:ok, output} ->
        branches =
          output
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
  def log(target, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    case run(target, ["log", "--oneline", "--format=%H\t%s\t%an\t%aI", "-#{limit}"]) do
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
  Returns {:ok, %{staged: [...], unstaged: [...]}} where each entry is
  %{status: "M"|"A"|"D"|"??", path: "..."}.

  Git's porcelain format uses two columns: XY where X = index (staged)
  and Y = worktree (unstaged). We split these into two lists.
  """
  def status(target) do
    case run(target, ["status", "--porcelain"]) do
      {:ok, output} ->
        {staged, unstaged} =
          output
          |> String.split("\n", trim: true)
          |> Enum.reduce({[], []}, fn line, {staged_acc, unstaged_acc} ->
            index = String.at(line, 0)
            worktree = String.at(line, 1)
            file_path = String.slice(line, 3..-1//1)

            staged_acc =
              if index not in [" ", "?", nil] do
                [%{status: index, path: file_path} | staged_acc]
              else
                staged_acc
              end

            unstaged_acc =
              cond do
                index == "?" and worktree == "?" ->
                  [%{status: "??", path: file_path} | unstaged_acc]

                worktree not in [" ", nil] ->
                  [%{status: worktree, path: file_path} | unstaged_acc]

                true ->
                  unstaged_acc
              end

            {staged_acc, unstaged_acc}
          end)

        {:ok, %{staged: Enum.reverse(staged), unstaged: Enum.reverse(unstaged)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Current HEAD short sha for a repo/worktree path."
  def current_revision(target) do
    case run(target, ["rev-parse", "--short", "HEAD"]) do
      {:ok, output} -> {:ok, String.trim(output)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Does the repo/worktree have uncommitted changes?"
  def dirty?(target) do
    case run(target, ["status", "--porcelain"]) do
      {:ok, ""} -> false
      {:ok, _output} -> true
      {:error, _} -> false
    end
  end

  @doc """
  Get diff for staged changes only.
  """
  def diff_staged(target, opts \\ []) do
    file = Keyword.get(opts, :file)
    args = ["diff", "--cached"] ++ if(file, do: ["--", file], else: [])
    run(target, args)
  end

  @doc """
  Working-tree diff stat vs HEAD, for the overview's ±changes badge.
  Returns `{:ok, %{added: n, removed: n}}` (tracked insertions/deletions,
  staged + unstaged). NOTE: `git diff` does not count untracked (brand-new)
  files, so a workspace whose only changes are new files reports 0/0.
  """
  def diff_stat(target) do
    case run(target, ["diff", "HEAD", "--shortstat"]) do
      {:ok, out} ->
        {:ok, %{added: shortstat_num(out, "insertion"), removed: shortstat_num(out, "deletion")}}

      err ->
        err
    end
  end

  # Pull the number before "insertions(+)" / "deletions(-)" from a --shortstat
  # line like " 3 files changed, 42 insertions(+), 13 deletions(-)". 0 when absent.
  defp shortstat_num(out, word) do
    case Regex.run(~r/(\d+)\s+#{word}/, out) do
      [_, n] -> String.to_integer(n)
      _ -> 0
    end
  end

  @doc """
  Get commit detail: files changed with insertions/deletions.
  Returns {:ok, %{sha, message, author, date, files: [%{path, insertions, deletions, status}]}}.
  """
  def commit_detail(target, sha) do
    case run(target, ["show", "--format=%H\t%s\t%an\t%aI", "--stat=200", "--numstat", sha]) do
      {:ok, output} ->
        lines = String.split(output, "\n", trim: true)

        case lines do
          [header | rest] ->
            case String.split(header, "\t", parts: 4) do
              [sha, message, author, date] ->
                files = parse_numstat(rest)

                {:ok,
                 %{
                   sha: sha,
                   message: message,
                   author: author,
                   date: date,
                   files: files
                 }}

              _ ->
                {:error, "Could not parse commit header"}
            end

          _ ->
            {:error, "Empty commit output"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Get the diff for a specific commit.
  Options:
    - :file — limit to a specific file
  """
  def commit_diff(target, sha, opts \\ []) do
    file = Keyword.get(opts, :file)
    args = ["show", "--format=", sha] ++ if(file, do: ["--", file], else: [])
    run(target, args)
  end

  defp parse_numstat(lines) do
    lines
    |> Enum.flat_map(fn line ->
      case String.split(line, "\t", parts: 3) do
        [ins, del, path] when ins != "" ->
          insertions = if ins == "-", do: 0, else: String.to_integer(ins)
          deletions = if del == "-", do: 0, else: String.to_integer(del)
          [%{path: path, insertions: insertions, deletions: deletions}]

        _ ->
          []
      end
    end)
  end

  @doc """
  Get diff output.

  Options:
    - :ref — compare against a specific ref (e.g. "HEAD~1")
    - :file — limit diff to a specific file
  """
  def diff(target, opts \\ []) do
    ref = Keyword.get(opts, :ref)
    file = Keyword.get(opts, :file)

    args =
      ["diff"] ++
        if(ref, do: [ref], else: []) ++
        if(file, do: ["--", file], else: [])

    run(target, args)
  end

  @doc """
  Show file contents at a specific ref.
  Returns {:ok, content} or {:error, reason}.
  """
  def show(target, ref, file) do
    run(target, ["show", "#{ref}:#{file}"])
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

  # Run a git command against a `target` that is EITHER a host path (binary —
  # legacy Local worktrees, where .git lives on disk) OR a runner function
  # (`(args -> {:ok, output} | {:error, reason})` — volume-backed workspaces, where
  # .git lives only inside the code volume and git must run in the container). This
  # is what lets the same parsing serve both host and container git.
  defp run(target, args) when is_binary(target), do: git(args, cd: target)
  defp run(target, args) when is_function(target, 1), do: target.(args)

  defp parse_worktree_list(output) do
    output
    |> String.split("\n\n", trim: true)
    |> Enum.map(fn block ->
      lines = String.split(block, "\n", trim: true)

      Enum.reduce(lines, %{}, fn line, acc ->
        cond do
          String.starts_with?(line, "worktree ") ->
            Map.put(acc, :path, String.trim_leading(line, "worktree "))

          String.starts_with?(line, "HEAD ") ->
            Map.put(acc, :head, String.trim_leading(line, "HEAD "))

          String.starts_with?(line, "branch ") ->
            Map.put(acc, :branch, String.trim_leading(line, "branch refs/heads/"))

          line == "bare" ->
            Map.put(acc, :bare, true)

          line == "detached" ->
            Map.put(acc, :detached, true)

          true ->
            acc
        end
      end)
    end)
    |> Enum.reject(&Map.has_key?(&1, :bare))
  end
end
