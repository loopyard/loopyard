defmodule BoomLooper.ProjectRegistry do
  @moduledoc """
  Registry of projects (git repos) and their branches (worktrees).
  Each project can have multiple branches, each with its own containers and agents.

  Stored in ETS — no persistence across restarts.
  """

  alias BoomLooper.Git
  alias BoomLooper.Workspace

  @projects_table :project_registry
  @branches_table :branch_registry

  def ensure_ets_tables do
    if :ets.whereis(@projects_table) == :undefined do
      :ets.new(@projects_table, [:named_table, :public, :set])
    end
    if :ets.whereis(@branches_table) == :undefined do
      :ets.new(@branches_table, [:named_table, :public, :set])
    end
    :ok
  end

  # --- Projects ---

  @doc """
  Add a project from a directory path. Detects the git repo root,
  creates the project, and registers the current branch.
  Returns {:ok, project, branch} or {:error, reason}.
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

          # Register the current branch
          {:ok, branch_name} = Git.current_branch(path)
          branch = find_or_create_branch(project.id, branch_name, path)

          # Also discover existing worktrees
          discover_worktrees(project)

          {:ok, project, branch}

        {:error, _} ->
          # Not a git repo — treat as a single-branch project
          project = find_or_create_project(path)
          branch = find_or_create_branch(project.id, "main", path)
          {:ok, project, branch}
      end
    end
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

  @doc "Remove a project and all its branches."
  def remove_project(id) do
    ensure_ets_tables()
    # Remove all branches for this project
    list_branches(id) |> Enum.each(&(:ets.delete(@branches_table, &1.id)))
    :ets.delete(@projects_table, id)
    :ok
  end

  # --- Branches ---

  @doc "List branches for a project."
  def list_branches(project_id) do
    ensure_ets_tables()
    :ets.tab2list(@branches_table)
    |> Enum.map(fn {_id, branch} -> branch end)
    |> Enum.filter(&(&1.project_id == project_id))
    |> Enum.sort_by(fn b -> if b.name == "main", do: "0", else: b.name end)
  end

  @doc "Get a branch by ID."
  def get_branch(id) do
    ensure_ets_tables()
    case :ets.lookup(@branches_table, id) do
      [{^id, branch}] -> branch
      [] -> nil
    end
  end

  @doc """
  Add a new branch to a project. Creates a git worktree.
  Returns {:ok, branch} or {:error, reason}.
  """
  def add_branch(project_id, branch_name) do
    ensure_ets_tables()
    project = get_project(project_id)

    unless project do
      {:error, "Project not found"}
    else
      # Check if branch already registered
      existing = list_branches(project_id) |> Enum.find(&(&1.name == branch_name))
      if existing do
        {:ok, existing}
      else
        case Git.worktree_add(project.path, branch_name) do
          {:ok, worktree_path} ->
            branch = create_branch(project_id, branch_name, worktree_path)
            {:ok, branch}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end

  @doc """
  Remove a branch. Stops containers and removes the git worktree.
  Cannot remove the main branch.
  """
  def remove_branch(branch_id) do
    ensure_ets_tables()
    branch = get_branch(branch_id)

    cond do
      is_nil(branch) -> {:error, "Branch not found"}
      branch.is_main -> {:error, "Cannot remove the main branch"}
      true ->
        # Remove worktree
        Git.worktree_remove(branch.path)
        :ets.delete(@branches_table, branch_id)
        :ok
    end
  end

  @doc "Update branch status (e.g. :running, :stopped)."
  def update_branch_status(branch_id, status) do
    ensure_ets_tables()
    case :ets.lookup(@branches_table, branch_id) do
      [{^branch_id, branch}] ->
        updated = %{branch | status: status}
        :ets.insert(@branches_table, {branch_id, updated})
        {:ok, updated}
      [] ->
        {:error, "Branch not found"}
    end
  end

  # --- Private ---

  defp find_or_create_project(repo_path) do
    id = project_id(repo_path)
    case get_project(id) do
      nil ->
        name = case Workspace.load(repo_path) do
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

  defp find_or_create_branch(project_id, branch_name, path) do
    id = branch_id(path)
    case get_branch(id) do
      nil -> create_branch(project_id, branch_name, path)
      existing -> existing
    end
  end

  defp create_branch(project_id, branch_name, path) do
    project = get_project(project_id)
    is_main = path == project.path
    id = branch_id(path)

    branch = %{
      id: id,
      project_id: project_id,
      name: branch_name,
      path: path,
      is_main: is_main,
      status: :stopped,
      added_at: DateTime.utc_now()
    }
    :ets.insert(@branches_table, {id, branch})
    branch
  end

  defp discover_worktrees(project) do
    case Git.worktree_list(project.path) do
      {:ok, worktrees} ->
        Enum.each(worktrees, fn wt ->
          branch_name = wt[:branch] || "detached"
          find_or_create_branch(project.id, branch_name, wt.path)
        end)

      {:error, _} ->
        :ok
    end
  end

  @doc "Generate a project ID from a repo path."
  def project_id(path) do
    Workspace.workspace_id(path)
  end

  @doc "Generate a branch ID from a worktree path."
  def branch_id(path) do
    Workspace.workspace_id(path)
  end
end
