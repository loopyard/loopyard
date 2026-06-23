defmodule Loopyard.Source.GitHub do
  @moduledoc """
  Source adapter stub for git-URL-based projects.

  Right now this is a minimal shim that lets the dispatch shape be honest.
  The real flow (clone-into-volume, ETS registration, etc.) still lives in
  `Loopyard.ProjectRegistry.add_from_url/2`; this module delegates to it.

  Future: OAuth, PR integration, branch discovery, merge/rebase via the
  GitHub API — all under `lib/loopyard/source/github/`.
  """

  require Logger

  alias Loopyard.Git

  @behaviour Loopyard.Source

  @impl true
  def add_project(git_url, opts) when is_binary(git_url) do
    case Loopyard.ProjectRegistry.add_from_url(git_url, opts) do
      {:ok, project, _workspace} -> {:ok, project}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def prepare_workspace(_project, _branch, _opts) do
    # GitHub workspace creation goes through `ProjectRegistry.add_from_url`
    # today (synchronous clone). PR2 will route it through the saga.
    {:error, :not_implemented}
  end

  @impl true
  def create_workspace(_project, _branch, _opts) do
    {:error, :not_implemented}
  end

  # All saga callbacks are no-ops for GitHub today — `add_from_url`
  # clones synchronously, so by the time Workspace.Setup runs against
  # a GitHub workspace it's already :ready. PR2 will route the clone
  # through the saga and replace these stubs.
  @impl true
  def do_create_worktree(_workspace) do
    Logger.warning(
      "[Source.GitHub] do_create_worktree called — GitHub workspaces use synchronous clone, not the setup saga"
    )

    :ok
  end

  @impl true
  def do_create_volume(_workspace) do
    Logger.warning(
      "[Source.GitHub] do_create_volume called — GitHub workspaces use synchronous clone, not the setup saga"
    )

    :ok
  end

  @impl true
  def do_seed_volume(_workspace, _callback, _opts \\ []) do
    Logger.warning(
      "[Source.GitHub] do_seed_volume called — GitHub workspaces use synchronous clone, not the setup saga"
    )

    :ok
  end

  @impl true
  def remove_workspace(_project, _workspace), do: :ok

  @impl true
  def remove_project(_project), do: :ok

  @impl true
  def checkout_path(_workspace), do: nil

  # GitHub workspaces today track the branch in `workspace.branch`
  # (set by ProjectRegistry.add_from_url). When PR / repo metadata
  # lands this can grow into `owner/repo#branch` or a PR title.
  @impl true
  def display_name(%{branch: branch}) when is_binary(branch) and branch != "", do: branch
  def display_name(%{name: name}) when is_binary(name) and name != "", do: name
  def display_name(_), do: ""

  @impl true
  def current_revision(_workspace), do: {:error, :not_applicable}

  @impl true
  def dirty?(_workspace), do: false

  @impl true
  def on_container_up(_workspace), do: :ok

  @impl true
  def on_container_down(_workspace), do: :ok

  # Git operations for GitHub-source workspaces. The code (and its `.git`) lives
  # ONLY inside the code volume — there is no host worktree — so git must run in
  # the workspace container against `/workspace`. We hand `Loopyard.Git` a runner
  # that execs git in the container, reusing all of its parsing.
  @impl true
  def git_log(_project, workspace, opts \\ []), do: Git.log(runner(workspace), opts)
  @impl true
  def git_status(_project, workspace), do: Git.status(runner(workspace))
  @impl true
  def git_diff(_project, workspace, opts \\ []), do: Git.diff(runner(workspace), opts)
  @impl true
  def git_show(_project, workspace, ref, path), do: Git.show(runner(workspace), ref, path)
  @impl true
  def git_diff_staged(_project, workspace, opts \\ []), do: Git.diff_staged(runner(workspace), opts)
  @impl true
  def git_commit_detail(_project, workspace, sha), do: Git.commit_detail(runner(workspace), sha)
  @impl true
  def git_commit_diff(_project, workspace, sha, opts \\ []),
    do: Git.commit_diff(runner(workspace), sha, opts)

  # A `Loopyard.Git` runner that execs `git` inside the workspace container against
  # the mounted code volume. `safe.directory` is set per-invocation because the
  # volume's files are root-owned (git refuses "dubious ownership" otherwise).
  defp runner(%{id: workspace_id}) when is_binary(workspace_id) do
    fn args ->
      case Loopyard.Workspace.ensure_working(workspace_id) do
        {:ok, container} ->
          cmd = "git -c safe.directory=/workspace -C /workspace " <> Enum.map_join(args, " ", &shq/1)

          case Loopyard.Docker.exec_in(container, cmd) do
            {:ok, output} -> {:ok, output}
            {:error, output} -> {:error, String.trim(to_string(output))}
          end

        {:error, reason} ->
          {:error, "workspace container unavailable for git: #{inspect(reason)}"}
      end
    end
  end

  defp runner(_), do: fn _args -> {:error, "no workspace id for git"} end

  # Single-quote an arg for safe interpolation into the container shell command.
  defp shq(s), do: "'" <> String.replace(to_string(s), "'", "'\\''") <> "'"
end
