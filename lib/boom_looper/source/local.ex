defmodule BoomLooper.Source.Local do
  @moduledoc """
  Source adapter for projects that live on the host filesystem as git repos.

  **Model:**

      host repo  →  host worktree (~/.boomlooper/worktrees/<ws_id>)
                         ↕ Mutagen (two-way-safe)
                    volume bl-<ws_id>-code   →  workspace container /workspace

  The host worktree owns git state (`.git` is excluded from the sync). The
  volume holds only files the agent edits. Mutagen keeps them coherent.

  Git is a host-side human concern for Local — the user runs `git commit`,
  `git push`, `git pull`, `git merge` from their own terminal against
  `~/.boomlooper/worktrees/<ws_id>`.
  """

  @behaviour BoomLooper.Source

  require Logger

  alias BoomLooper.{Git, VolumeManager, Workspace}
  alias BoomLooper.Source.Local.{Mutagen, SyncMonitor, Worktree}

  # --- add_project ---
  #
  # Pure project-map construction. No ETS, no ProjectStore side effects —
  # `ProjectRegistry.add/1` owns persistence and is what callers should use
  # at the application level.

  @impl true
  def add_project(path, _opts \\ []) do
    path = Path.expand(path)

    cond do
      not File.dir?(path) ->
        {:error, "Directory does not exist: #{path}"}

      true ->
        # If mutagen isn't installed, we still register the project so the
        # UI can show it — Local workspaces will just report :errored on
        # their sync card until mutagen is installed. Better than a hard
        # fail that blocks the user from even seeing the project.
        case Git.repo_root(path) do
          {:ok, repo_root} -> {:ok, build_project(repo_root, is_git: true)}
          {:error, _} -> {:ok, build_project(path, is_git: false)}
        end
    end
  end

  defp build_project(repo_root, opts) do
    is_git = Keyword.fetch!(opts, :is_git)

    default_branch =
      case Git.current_branch(repo_root) do
        {:ok, branch} -> branch
        _ -> "main"
      end

    id = Workspace.workspace_id(repo_root)
    name = BoomLooper.ProjectRegistry.default_name_from_path(repo_root) || Path.basename(repo_root)

    %{
      id: id,
      name: name,
      path: repo_root,
      is_git: is_git,
      source_type: :local,
      source_config: %{
        repo_root: repo_root,
        default_branch: default_branch
      },
      added_at: DateTime.utc_now()
    }
  end

  # --- create_workspace ---

  @impl true
  def create_workspace(project, branch, _opts \\ []) do
    workspace_id = Workspace.workspace_id_from_git(project.path, branch)
    volume_name = VolumeManager.code_volume_name(workspace_id)

    with {:ok, worktree_path} <- Worktree.create(project.path, workspace_id, branch),
         :ok <- VolumeManager.create_volume(volume_name) do
      # Copy .boomlooper config from main repo to the new worktree so it
      # inherits Dockerfile, docker-compose.yml, and workspace metadata.
      # Skip agents.log (agent state is per-workspace).
      copy_boomlooper_config(project.path, worktree_path)

      workspace = %{
        id: workspace_id,
        project_id: project.id,
        name: branch,
        branch: branch,
        base_branch: Map.get(project.source_config || %{}, :default_branch),
        worktree_path: worktree_path,
        volume: volume_name,
        volume_based: true,
        path: Path.join([Workspace.home_dir(), "workspaces", workspace_id]),
        is_main: false,
        status: :stopped,
        added_at: DateTime.utc_now()
      }

      {:ok, workspace}
    end
  end

  # --- remove_workspace ---

  @impl true
  def remove_workspace(_project, workspace) do
    workspace_id = workspace.id

    # Mark the SyncMonitor for removal so its terminate/2 actually tears
    # down the mutagen session (the default is to leave it alone so
    # supervisor restarts don't churn it).
    SyncMonitor.prepare_for_removal(workspace_id)

    # Belt + braces: also terminate directly in case the SyncMonitor isn't
    # running (e.g. the workspace never fully booted).
    Mutagen.terminate_sync(workspace_id)

    # Remove the host worktree.
    Worktree.remove(workspace_id)

    # Delete the code volume. Cache/deps volumes are managed by compose.
    if vol = workspace[:volume] do
      VolumeManager.delete_volume(vol)
    end

    :ok
  end

  # --- remove_project ---
  # Registry-level teardown (ETS, ProjectStore, virtual dirs) stays in
  # `ProjectRegistry.remove_project/1`. This callback is a no-op for Local.

  @impl true
  def remove_project(_project), do: :ok

  # Copy .boomlooper config from the main repo to a new worktree.
  # This gives the worktree the same Dockerfile, docker-compose.yml,
  # and workspace metadata (name, system prompt) as main.
  defp copy_boomlooper_config(main_path, worktree_path) do
    src_repo = Path.join(main_path, ".boomlooper/repo")
    src_workspace = Path.join(main_path, ".boomlooper/workspace")
    dst_repo = Path.join(worktree_path, ".boomlooper/repo")
    dst_workspace = Path.join(worktree_path, ".boomlooper/workspace")

    if File.dir?(src_repo) do
      File.mkdir_p!(dst_repo)
      # Copy workspace.json (project name, system prompt)
      for file <- ~w(workspace.json) do
        src = Path.join(src_repo, file)
        if File.exists?(src), do: File.cp!(src, Path.join(dst_repo, file))
      end
    end

    if File.dir?(src_workspace) do
      File.mkdir_p!(dst_workspace)
      # Copy Dockerfile and docker-compose.yml (not agents.log)
      for file <- ~w(Dockerfile docker-compose.yml) do
        src = Path.join(src_workspace, file)
        if File.exists?(src), do: File.cp!(src, Path.join(dst_workspace, file))
      end
    end
  rescue
    e ->
      Logger.warning("[Source.Local] Failed to copy .boomlooper config to worktree: #{Exception.message(e)}")
  end

  # --- Queries ---

  @impl true
  def checkout_path(%{worktree_path: path}) when is_binary(path), do: path
  def checkout_path(%{id: id}), do: Worktree.path_for(id)
  def checkout_path(_), do: nil

  @impl true
  def current_revision(%{id: id}), do: Worktree.current_revision(id)
  def current_revision(_), do: {:error, :no_workspace}

  @impl true
  def dirty?(%{id: id}), do: Worktree.dirty?(id)
  def dirty?(_), do: false

  # --- Container hooks ---

  @impl true
  def on_container_up(%{id: id}) do
    SyncMonitor.container_up(id)
    :ok
  end

  def on_container_up(_), do: :ok

  @impl true
  def on_container_down(%{id: id}) do
    SyncMonitor.container_down(id)
    :ok
  end

  def on_container_down(_), do: :ok
end
