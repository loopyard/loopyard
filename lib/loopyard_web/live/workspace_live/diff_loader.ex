defmodule LoopyardWeb.Live.WorkspaceLive.DiffLoader do
  @moduledoc """
  Git diff fetches for the workspace_live diff viewer.

  Pulled out of `WorkspaceLive` so the five scattered LiveView callbacks
  (handle_params × 4, handle_event × 3, handle_async × 4) share one
  vocabulary and one place to read.

  Every function here is pure delegation to the project's `Source`
  adapter (Local or GitHub), returning the raw diff string or a
  human-readable "could not load" fallback. No LiveView state is
  involved — the caller owns the `start_async` / assigns plumbing.
  """

  alias Loopyard.Source

  @fallback "(could not load diff)"

  @doc """
  Diff for a file at one side of the working tree.

    * `:unstaged` — `git diff HEAD <file>` equivalent
    * `:staged`   — `git diff --cached HEAD <file>` equivalent
  """
  def file_diff(project, workspace_entry, file_path, :unstaged) do
    adapter(project).git_diff(project, workspace_entry, file: file_path)
    |> unwrap(@fallback)
  end

  def file_diff(project, workspace_entry, file_path, :staged) do
    adapter(project).git_diff_staged(project, workspace_entry, file: file_path)
    |> unwrap(@fallback)
  end

  @doc "Full-file diff from a prior commit."
  def commit_file_diff(project, workspace_entry, sha, file_path) do
    adapter(project).git_commit_diff(project, workspace_entry, sha, file: file_path)
    |> unwrap(@fallback)
  end

  @doc "All changes in a prior commit, as one diff string."
  def commit_diff(project, workspace_entry, sha) do
    adapter(project).git_diff(project, workspace_entry, ref: "#{sha}~1..#{sha}")
    |> unwrap("(could not load diff for commit #{String.slice(sha, 0..6)})")
  end

  @doc "Workspace-level diff for a single file (unstaged, working-tree vs HEAD)."
  def working_file_diff(project, workspace_entry, file_path) do
    adapter(project).git_diff(project, workspace_entry, file: file_path)
    |> unwrap(@fallback)
  end

  @doc "Commit metadata (author, subject, changed files) for a SHA."
  def commit_detail(project, workspace_entry, sha) do
    case adapter(project).git_commit_detail(project, workspace_entry, sha) do
      {:ok, commit} -> commit
      _ -> nil
    end
  end

  # --- Private ---

  defp adapter(project), do: Source.for_project(project)

  defp unwrap({:ok, value}, _fallback), do: value
  defp unwrap(_, fallback), do: fallback
end
