defmodule BoomLooper.Source.GitHub do
  @moduledoc """
  Source adapter stub for git-URL-based projects.

  Right now this is a minimal shim that lets the dispatch shape be honest.
  The real flow (clone-into-volume, ETS registration, etc.) still lives in
  `BoomLooper.ProjectRegistry.add_from_url/2`; this module delegates to it.

  Future: OAuth, PR integration, branch discovery, merge/rebase via the
  GitHub API — all under `lib/boom_looper/source/github/`.
  """

  @behaviour BoomLooper.Source

  @impl true
  def add_project(git_url, opts) when is_binary(git_url) do
    case BoomLooper.ProjectRegistry.add_from_url(git_url, opts) do
      {:ok, project, _workspace} -> {:ok, project}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def create_workspace(_project, _branch, _opts) do
    {:error, :not_implemented}
  end

  @impl true
  def remove_workspace(_project, _workspace), do: :ok

  @impl true
  def remove_project(_project), do: :ok

  @impl true
  def checkout_path(_workspace), do: nil

  @impl true
  def current_revision(_workspace), do: {:error, :not_applicable}

  @impl true
  def dirty?(_workspace), do: false

  @impl true
  def on_container_up(_workspace), do: :ok

  @impl true
  def on_container_down(_workspace), do: :ok

  # Git operations not supported for GitHub source (yet)
  @impl true
  def git_log(_project, _workspace, _opts \\ []), do: {:error, :not_implemented}
  @impl true
  def git_status(_project, _workspace), do: {:error, :not_implemented}
  @impl true
  def git_diff(_project, _workspace, _opts \\ []), do: {:error, :not_implemented}
  @impl true
  def git_show(_project, _workspace, _ref, _path), do: {:error, :not_implemented}
  @impl true
  def git_diff_staged(_project, _workspace, _opts \\ []), do: {:error, :not_implemented}
  @impl true
  def git_commit_detail(_project, _workspace, _sha), do: {:error, :not_implemented}
  @impl true
  def git_commit_diff(_project, _workspace, _sha, _opts \\ []), do: {:error, :not_implemented}
end
