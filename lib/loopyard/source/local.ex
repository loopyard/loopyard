defmodule Loopyard.Source.Local do
  @moduledoc """
  Source adapter for projects that live on the host filesystem as git repos.

  **Model:**

      host repo  →  host worktree (~/.loopyard/worktrees/<ws_id>)
                         ↕ Mutagen (two-way-safe)
                    volume loopyard-<ws_id>-code   →  workspace container /workspace

  The host worktree owns git state (`.git` is excluded from the sync). The
  volume holds only files the agent edits. Mutagen keeps them coherent.

  Git is a host-side human concern for Local — the user runs `git commit`,
  `git push`, `git pull`, `git merge` from their own terminal against
  `~/.loopyard/worktrees/<ws_id>`.
  """

  @behaviour Loopyard.Source

  require Logger

  alias Loopyard.{Git, VolumeIO, VolumeManager, Workspace}
  alias Loopyard.Source.Local.{Mutagen, SyncMonitor, Worktree}

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

    name =
      Loopyard.ProjectRegistry.default_name_from_path(repo_root) || Path.basename(repo_root)

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

  # --- prepare_workspace (no I/O) ---
  #
  # Build the workspace map only — no git, no Docker, no filesystem
  # writes. The setup saga (Workspace.Setup) calls do_create_worktree,
  # do_create_volume, do_seed_volume in turn to actually materialize
  # the workspace.
  #
  # Critical: this must NOT touch the filesystem. The saga is responsible
  # for I/O so failures surface through the structured error system,
  # not as inline crashes in the LV handler.

  @impl true
  def prepare_workspace(project, branch, _opts \\ []) do
    workspace_id = Workspace.workspace_id_from_git(project.path, branch)
    volume_name = VolumeManager.code_volume_name(workspace_id)
    worktree_path = Worktree.path_for(workspace_id)

    workspace = %{
      id: workspace_id,
      project_id: project.id,
      name: branch,
      branch: branch,
      base_branch: Map.get(project.source_config || %{}, :default_branch),
      worktree_path: worktree_path,
      volume: volume_name,
      volume_based: true,
      path: Workspace.compose_dir(workspace_id),
      is_main: false,
      status: :stopped,
      added_at: DateTime.utc_now(),
      # Stash the project root so the saga can read it without re-fetching
      # the project from ETS (which would race with project rename / etc.).
      source_root: project.path
    }

    {:ok, workspace}
  end

  # --- create_workspace (legacy, synchronous) ---
  #
  # Kept for callers that haven't migrated to the saga. Inlines the work
  # the saga would otherwise spread across :worktree, :volume, :seeding
  # — minus the seed (a sync clone-via-rsync would block the LV handler
  # for minutes on big repos, exactly the regression we just fixed).
  # New code paths use `prepare_workspace/3` + `Workspace.Setup.start/1`.

  @impl true
  def create_workspace(project, branch, opts \\ []) do
    with {:ok, ws} <- prepare_workspace(project, branch, opts),
         :ok <- do_create_worktree(ws),
         :ok <- do_create_volume(ws) do
      {:ok, ws}
    end
  end

  # --- Setup-saga steps ---

  @impl true
  def do_create_worktree(workspace) do
    repo_path = workspace[:source_root] || resolve_source_root(workspace)
    worktree_path = workspace.worktree_path

    cond do
      is_nil(repo_path) ->
        {:error, :source_path_missing}

      not File.dir?(repo_path) ->
        {:error, {:source_path_missing, repo_path}}

      true ->
        # Idempotent: if the worktree already exists from a previous
        # attempt (Retry, server restart mid-saga), remove it first so
        # `git worktree add` doesn't fail with "already registered."
        # Pass repo_path so the deregistration runs in the owning repo.
        Worktree.remove(workspace.id, repo_path)

        case Worktree.create(repo_path, workspace.id, workspace.branch) do
          {:ok, ^worktree_path} ->
            finish_worktree(repo_path, worktree_path)

          {:ok, other_path} when is_binary(other_path) ->
            finish_worktree(repo_path, other_path)

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp finish_worktree(repo_path, worktree_path) do
    copy_loopyard_config(repo_path, worktree_path)
    :ok
  end

  defp resolve_source_root(workspace) do
    case Loopyard.ProjectRegistry.get_project(workspace[:project_id]) do
      %{path: path} -> path
      _ -> nil
    end
  end

  @impl true
  def do_create_volume(workspace) do
    case VolumeManager.create_volume(workspace.volume) do
      :ok -> :ok
      {:error, _} = err -> err
    end
  end

  # --- do_seed_volume ---
  #
  # Slow phase. Worktree already exists from :worktree; volume already
  # exists from :volume. We rsync the worktree's files into the volume
  # so the workspace is browsable and agents can read it BEFORE the
  # cluster is up. Mutagen takes over for live sync later — its first
  # scan against an already-matching tree is a no-op.

  @impl true
  def do_seed_volume(workspace, callback, _opts \\ []) do
    src = workspace[:worktree_path]
    vol = workspace[:volume]

    cond do
      not is_binary(src) ->
        {:error, :source_path_missing}

      not File.dir?(src) ->
        {:error, {:source_path_missing, src}}

      not is_binary(vol) ->
        {:error, :no_volume}

      true ->
        case VolumeIO.seed_from_host(vol, src, callback: callback) do
          {:ok, _output} -> :ok
          {:error, reason} -> {:error, reason}
        end
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

  # Copy .loopyard config from the main repo to a new worktree.
  # This gives the worktree the same Dockerfile, docker-compose.yml,
  # and workspace metadata (name, system prompt) as main.
  defp copy_loopyard_config(main_path, worktree_path) do
    src_repo = Path.join(main_path, ".loopyard/repo")
    src_workspace = Path.join(main_path, ".loopyard/workspace")
    dst_repo = Path.join(worktree_path, ".loopyard/repo")
    dst_workspace = Path.join(worktree_path, ".loopyard/workspace")

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
      Logger.warning(
        "[Source.Local] Failed to copy .loopyard config to worktree: #{Exception.message(e)}"
      )
  end

  # --- Queries ---

  @impl true
  def checkout_path(%{worktree_path: path}) when is_binary(path), do: path
  def checkout_path(%{id: id}), do: Worktree.path_for(id)
  def checkout_path(_), do: nil

  # Local workspaces ARE branches. The display label is the branch name
  # as recorded in the workspace map. No git CLI shell-out here — the
  # branch field is set at workspace creation and is the authoritative
  # source for "what does the user call this workspace."
  @impl true
  def display_name(%{branch: branch}) when is_binary(branch) and branch != "", do: branch
  def display_name(%{name: name}) when is_binary(name) and name != "", do: name
  def display_name(_), do: ""

  # Resolve against the workspace's actual checkout — `worktree_path` for a
  # branch workspace, or the project root for the main workspace (which has
  # no worktree under ~/.loopyard/worktrees). Mirrors the git_* callbacks so
  # the main workspace reports real values instead of :worktree_missing.
  @impl true
  def current_revision(workspace) do
    case worktree_path_for(workspace) do
      {:ok, path} -> Git.current_revision(path)
      {:error, _} -> {:error, :no_workspace}
    end
  end

  @impl true
  def dirty?(workspace) do
    case worktree_path_for(workspace) do
      {:ok, path} -> Git.dirty?(path)
      {:error, _} -> false
    end
  end

  # --- Git operations ---

  @impl true
  def git_log(_project, workspace, opts \\ []) do
    case worktree_path_for(workspace) do
      {:ok, path} -> Git.log(path, opts)
      {:error, _} = err -> err
    end
  end

  @impl true
  def git_status(_project, workspace) do
    case worktree_path_for(workspace) do
      {:ok, path} -> Git.status(path)
      {:error, _} = err -> err
    end
  end

  @impl true
  def git_diff(_project, workspace, opts \\ []) do
    case worktree_path_for(workspace) do
      {:ok, path} -> Git.diff(path, opts)
      {:error, _} = err -> err
    end
  end

  @impl true
  def git_show(_project, workspace, ref, file) do
    case worktree_path_for(workspace) do
      {:ok, path} -> Git.show(path, ref, file)
      {:error, _} = err -> err
    end
  end

  @impl true
  def git_diff_staged(_project, workspace, opts \\ []) do
    case worktree_path_for(workspace) do
      {:ok, path} -> Git.diff_staged(path, opts)
      {:error, _} = err -> err
    end
  end

  @impl true
  def git_commit_detail(_project, workspace, sha) do
    case worktree_path_for(workspace) do
      {:ok, path} -> Git.commit_detail(path, sha)
      {:error, _} = err -> err
    end
  end

  @impl true
  def git_commit_diff(_project, workspace, sha, opts \\ []) do
    case worktree_path_for(workspace) do
      {:ok, path} -> Git.commit_diff(path, sha, opts)
      {:error, _} = err -> err
    end
  end

  defp worktree_path_for(%{worktree_path: path}) when is_binary(path), do: {:ok, path}
  defp worktree_path_for(%{path: path}) when is_binary(path), do: {:ok, path}
  defp worktree_path_for(_), do: {:error, :no_workspace_path}

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
