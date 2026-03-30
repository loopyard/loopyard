defmodule BoomLooper.ProjectRegistry do
  @moduledoc """
  Registry of projects (git repos) and their workspaces (worktrees).
  Each project can have multiple workspaces, each with its own containers and agents.

  Projects are stored in ETS for fast access, and persisted to
  `~/.boomlooper/projects.json` via `ProjectStore`. On startup,
  `restore/0` re-registers persisted projects.
  """

  require Logger

  alias BoomLooper.Git
  alias BoomLooper.ProjectStore
  alias BoomLooper.Workspace

  @projects_table :project_registry
  @workspaces_table :workspace_registry

  def ensure_ets_tables do
    if :ets.whereis(@projects_table) == :undefined do
      :ets.new(@projects_table, [:named_table, :public, :set])
    end
    if :ets.whereis(@workspaces_table) == :undefined do
      :ets.new(@workspaces_table, [:named_table, :public, :set])
    end
    :ok
  end

  # --- Projects ---

  @doc """
  Add a project from a git URL. Clones the repo into a volume and registers the workspace.
  Returns {:ok, project, workspace} or {:error, reason}.

  Options:
    - branch: branch to clone (default: "main")
    - token: GitHub token for auth (optional)
  """
  def add_from_url(git_url, opts \\ []) do
    ensure_ets_tables()

    branch = Keyword.get(opts, :branch, "main")
    token = Keyword.get(opts, :token)

    project_id = Workspace.project_id_from_git(git_url)
    workspace_id = Workspace.workspace_id_from_git(git_url, branch)

    # Find or create project
    project = case get_project(project_id) do
      nil ->
        name = extract_repo_name(git_url)
        proj = %{
          id: project_id,
          name: name,
          git_url: git_url,
          is_git: true,
          volume_based: true,
          added_at: DateTime.utc_now()
        }
        :ets.insert(@projects_table, {project_id, proj})
        proj

      existing ->
        existing
    end

    # Find or create workspace
    workspace = case get_workspace(workspace_id) do
      nil ->
        volume_name = BoomLooper.VolumeManager.code_volume_name(workspace_id)
        ws = %{
          id: workspace_id,
          project_id: project_id,
          name: branch,
          branch: branch,
          git_url: git_url,
          volume: volume_name,
          volume_based: true,
          status: :stopped,
          added_at: DateTime.utc_now()
        }
        :ets.insert(@workspaces_table, {workspace_id, ws})
        ws

      existing ->
        existing
    end

    # Clone code into volume if not already done
    volume_name = BoomLooper.VolumeManager.code_volume_name(workspace_id)
    unless BoomLooper.VolumeManager.volume_has_code?(volume_name) do
      case BoomLooper.VolumeManager.clone_into_volume(volume_name, git_url, branch: branch, token: token) do
        {:ok, _} -> :ok
        {:error, reason} -> Logger.warning("[ProjectRegistry] Clone failed: #{reason}")
      end
    end

    # Persist to disk (store git_url instead of path)
    ProjectStore.add(git_url)

    {:ok, project, workspace}
  end

  defp extract_repo_name(git_url) do
    git_url
    |> String.replace(~r/\.git$/, "")
    |> String.split("/")
    |> List.last()
    |> String.split(":")
    |> List.last()
  end

  @doc """
  Add a project from a directory path. Detects the git repo root,
  creates the project, and registers the current workspace.
  Returns {:ok, project, workspace} or {:error, reason}.
  """
  def add(path) do
    path = Path.expand(path)

    unless File.dir?(path) do
      {:error, "Directory does not exist: #{path}"}
    else
      ensure_ets_tables()

      case Git.repo_root(path) do
        {:ok, repo_root} ->
          project = find_or_create_project(repo_root)

          # Register the current workspace
          {:ok, branch_name} = Git.current_branch(path)
          workspace = find_or_create_workspace(project.id, branch_name, path)

          # Also discover existing worktrees
          discover_worktrees(project)

          # Persist to disk
          ProjectStore.add(project.path)

          {:ok, project, workspace}

        {:error, _} ->
          # Not a git repo — treat as a single-workspace project
          project = find_or_create_project(path)
          workspace = find_or_create_workspace(project.id, "main", path)

          # Persist to disk
          ProjectStore.add(project.path)

          {:ok, project, workspace}
      end
    end
  end

  @doc """
  Restore projects from disk on startup.

  Re-registers all projects from `~/.boomlooper/projects.json`.
  ServiceManager will detect running containers and reconnect.
  """
  def restore do
    ensure_ets_tables()

    for entry <- ProjectStore.load() do
      result = cond do
        # Git URL (volume-based)
        String.starts_with?(entry, "git@") or String.starts_with?(entry, "https://") ->
          add_from_url(entry)

        # Local path (bind-mount based)
        true ->
          add(entry)
      end

      case result do
        {:ok, _project, _workspace} ->
          :ok

        {:error, reason} ->
          Logger.warning("[ProjectRegistry] Failed to restore project #{entry}: #{reason}")
      end
    end

    :ok
  end

  @doc "List all projects."
  def list_projects do
    ensure_ets_tables()
    :ets.tab2list(@projects_table)
    |> Enum.map(fn {_id, project} -> project end)
    |> Enum.sort_by(& &1.name)
  end

  @doc "Get a project by ID."
  def get_project(id) do
    ensure_ets_tables()
    case :ets.lookup(@projects_table, id) do
      [{^id, project}] -> project
      [] -> nil
    end
  end

  @doc """
  Remove a project and all its workspaces.
  Stops agents, tears down Docker containers, and deletes volumes/files.
  """
  def remove_project(id) do
    ensure_ets_tables()
    project = get_project(id)
    workspaces = list_workspaces(id)

    # Stop all agents and clean up ETS entries
    all_agents = BoomLooper.ChatAgent.list_agents()

    Enum.each(workspaces, fn workspace ->
      # Match agents by workspace_id or path
      all_agents
      |> Enum.filter(fn a ->
        a[:workspace_id] == workspace.id ||
        a[:bind_mount] == workspace[:path] ||
        a[:working_dir] == workspace[:path]
      end)
      |> Enum.each(fn agent ->
        BoomLooper.ChatAgent.stop_agent(agent.id)
        BoomLooper.ChatAgent.remove_agent(agent.id)
      end)

      BoomLooper.WorkspaceSupervisor.stop_workspace(workspace.id)
    end)

    if project do
      # Remove from disk persistence
      persistence_key = project[:git_url] || project[:path]
      ProjectStore.remove(persistence_key)

      # Handle cleanup based on project type
      if project[:volume_based] do
        # Volume-based: delete volumes
        Task.start(fn ->
          Enum.each(workspaces, fn ws ->
            try do
              # Stop compose first
              BoomLooper.Compose.down_volumes(Workspace.home_dir(), ws.id)
              # Delete code and cache volumes
              BoomLooper.VolumeManager.delete_volume(ws[:volume])
              BoomLooper.VolumeManager.delete_volume(BoomLooper.VolumeManager.cache_volume_name(ws.id))
            rescue
              _ -> :ok
            catch
              _, _ -> :ok
            end
          end)
        end)
      else
        # Path-based: delete .boomlooper directory and tear down containers
        boomlooper_dir = Path.join(project.path, ".boomlooper")
        File.rm_rf(boomlooper_dir)

        workspace_paths = Enum.map(workspaces, fn ws ->
          {ws.path, Workspace.workspace_id(ws.path)}
        end)

        Task.start(fn ->
          Enum.each(workspace_paths, fn {path, workspace_id} ->
            try do
              BoomLooper.Compose.down(path, workspace_id)
            rescue
              _ -> :ok
            catch
              _, _ -> :ok
            end
          end)
        end)
      end
    end

    # Remove from ETS
    Enum.each(workspaces, fn ws -> :ets.delete(@workspaces_table, ws.id) end)
    :ets.delete(@projects_table, id)
    :ok
  end

  # --- Workspaces ---

  @doc "List workspaces for a project."
  def list_workspaces(project_id) do
    ensure_ets_tables()
    :ets.tab2list(@workspaces_table)
    |> Enum.map(fn {_id, workspace} -> workspace end)
    |> Enum.filter(&(&1.project_id == project_id))
    |> Enum.sort_by(fn w -> if w.name == "main", do: "0", else: w.name end)
  end

  @doc "Get a workspace by ID."
  def get_workspace(id) do
    ensure_ets_tables()
    case :ets.lookup(@workspaces_table, id) do
      [{^id, workspace}] -> workspace
      [] -> nil
    end
  end

  @doc """
  Add a new workspace to a project. Creates a git worktree.
  Returns {:ok, workspace} or {:error, reason}.
  """
  def add_workspace(project_id, workspace_name) do
    ensure_ets_tables()
    project = get_project(project_id)

    unless project do
      {:error, "Project not found"}
    else
      # Check if workspace already registered
      existing = list_workspaces(project_id) |> Enum.find(&(&1.name == workspace_name))
      if existing do
        {:ok, existing}
      else
        case Git.worktree_add(project.path, workspace_name) do
          {:ok, worktree_path} ->
            workspace = create_workspace(project_id, workspace_name, worktree_path)
            {:ok, workspace}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end

  @doc """
  Remove a workspace. Stops containers and removes the git worktree.
  Cannot remove the main workspace.
  """
  def remove_workspace(workspace_id) do
    ensure_ets_tables()
    workspace = get_workspace(workspace_id)

    cond do
      is_nil(workspace) -> {:error, "Workspace not found"}
      workspace.is_main -> {:error, "Cannot remove the main workspace"}
      true ->
        # Remove worktree
        Git.worktree_remove(workspace.path)
        :ets.delete(@workspaces_table, workspace_id)
        :ok
    end
  end

  @doc "Update workspace status (e.g. :running, :stopped)."
  def update_workspace_status(workspace_id, status) do
    ensure_ets_tables()
    case :ets.lookup(@workspaces_table, workspace_id) do
      [{^workspace_id, workspace}] ->
        updated = %{workspace | status: status}
        :ets.insert(@workspaces_table, {workspace_id, updated})
        {:ok, updated}
      [] ->
        {:error, "Workspace not found"}
    end
  end

  # --- Private ---

  defp find_or_create_project(repo_path) do
    id = project_id(repo_path)
    case get_project(id) do
      nil ->
        ws_id = Workspace.workspace_id(repo_path)
        name = case Workspace.load_from_volume("code-#{ws_id}") do
          {:ok, ws} when ws.name != nil -> ws.name
          _ -> Path.basename(repo_path)
        end

        project = %{
          id: id,
          name: name,
          path: repo_path,
          is_git: Git.is_repo?(repo_path),
          added_at: DateTime.utc_now()
        }
        :ets.insert(@projects_table, {id, project})
        project

      existing ->
        existing
    end
  end

  defp find_or_create_workspace(project_id, workspace_name, path) do
    id = workspace_id(path)
    case get_workspace(id) do
      nil -> create_workspace(project_id, workspace_name, path)
      existing -> existing
    end
  end

  defp create_workspace(project_id, workspace_name, path) do
    project = get_project(project_id)
    is_main = path == project.path
    id = workspace_id(path)

    workspace = %{
      id: id,
      project_id: project_id,
      name: workspace_name,
      path: path,
      is_main: is_main,
      status: :stopped,
      added_at: DateTime.utc_now()
    }
    :ets.insert(@workspaces_table, {id, workspace})
    workspace
  end

  defp discover_worktrees(project) do
    case Git.worktree_list(project.path) do
      {:ok, worktrees} ->
        Enum.each(worktrees, fn wt ->
          workspace_name = wt[:branch] || "detached"
          find_or_create_workspace(project.id, workspace_name, wt.path)
        end)

      {:error, _} ->
        :ok
    end
  end

  @doc "Generate a project ID from a repo path."
  def project_id(path) do
    Workspace.workspace_id(path)
  end

  @doc "Generate a workspace ID from a worktree path."
  def workspace_id(path) do
    Workspace.workspace_id(path)
  end
end
