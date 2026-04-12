defmodule BoomLooper.WorkspaceRegistry do
  @moduledoc """
  Registry of workspaces (worktrees) within projects.
  Each workspace has its own containers, volumes, and agents.
  Stored in ETS for fast access.
  """

  alias BoomLooper.Workspace

  @workspaces_table :workspace_registry

  @doc "Get a workspace by ID."
  def get_workspace(id) do
    case :ets.lookup(@workspaces_table, id) do
      [{^id, workspace}] -> normalize_workspace(workspace)
      [] -> nil
    end
  end

  @doc "List workspaces for a project."
  def list_workspaces(project_id) do
    :ets.tab2list(@workspaces_table)
    |> Enum.map(fn {_id, workspace} -> normalize_workspace(workspace) end)
    |> Enum.filter(&(&1.project_id == project_id))
    |> Enum.sort_by(fn w -> if w.name == "main", do: "0", else: w.name end)
  end

  @doc """
  Add a new workspace to a project. Delegates to the project's Source adapter.
  Returns {:ok, workspace} or {:error, reason}.
  """
  def add_workspace(project_id, branch_name) do
    project = BoomLooper.ProjectRegistry.get_project(project_id)

    unless project do
      {:error, "Project not found"}
    else
      # Check if a workspace with this branch is already registered
      existing = list_workspaces(project_id) |> Enum.find(&(&1.name == branch_name))
      if existing do
        {:ok, existing}
      else
        adapter = BoomLooper.Source.for_project(project)

        case adapter.create_workspace(project, branch_name, []) do
          {:ok, workspace} ->
            :ets.insert(@workspaces_table, {workspace.id, workspace})
            {:ok, workspace}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end

  @doc """
  Remove a workspace. Stops containers and tears down adapter-owned state
  (host worktree, volume, sync session, etc.). Cannot remove the main
  workspace.
  """
  def remove_workspace(workspace_id) do
    workspace = get_workspace(workspace_id)

    cond do
      is_nil(workspace) ->
        {:error, "Workspace not found"}

      workspace.is_main ->
        {:error, "Cannot remove the main workspace"}

      true ->
        project = BoomLooper.ProjectRegistry.get_project(workspace.project_id)
        adapter = BoomLooper.Source.for_project(project || %{})
        adapter.remove_workspace(project || %{}, workspace)
        :ets.delete(@workspaces_table, workspace_id)
        :ok
    end
  end

  @doc "Update workspace status (e.g. :running, :stopped)."
  def update_workspace_status(workspace_id, status) do
    case :ets.lookup(@workspaces_table, workspace_id) do
      [{^workspace_id, workspace}] ->
        updated = %{workspace | status: status}
        :ets.insert(@workspaces_table, {workspace_id, updated})
        {:ok, updated}
      [] ->
        {:error, "Workspace not found"}
    end
  end

  @doc "Generate a workspace ID from a worktree path."
  def workspace_id(path) do
    Workspace.workspace_id(path)
  end

  @doc "Find or create a workspace for a project."
  def find_or_create_workspace(project_id, workspace_name, path) do
    id = workspace_id(path)
    case get_workspace(id) do
      nil -> create_workspace(project_id, workspace_name, path)
      existing -> existing
    end
  end

  @doc false
  def insert(workspace_id, workspace) do
    :ets.insert(@workspaces_table, {workspace_id, workspace})
  end

  @doc false
  def delete(workspace_id) do
    :ets.delete(@workspaces_table, workspace_id)
  end

  # --- Private ---

  defp create_workspace(project_id, workspace_name, path) do
    project = BoomLooper.ProjectRegistry.get_project(project_id)
    is_main = path == project.path
    id = workspace_id(path)

    worktree_path =
      cond do
        project && project[:source_type] == :local && is_main -> path
        true -> nil
      end

    workspace = %{
      id: id,
      project_id: project_id,
      name: workspace_name,
      path: path,
      worktree_path: worktree_path,
      branch: workspace_name,
      is_main: is_main,
      status: :stopped,
      added_at: DateTime.utc_now()
    }
    :ets.insert(@workspaces_table, {id, workspace})
    workspace
  end

  defp normalize_workspace(ws) do
    ws
    |> maybe_add_path()
    |> maybe_add_is_main()
  end

  defp maybe_add_path(%{path: _} = ws), do: ws
  defp maybe_add_path(%{volume_based: true, id: id} = ws) do
    Map.put(ws, :path, Path.join([Workspace.home_dir(), "workspaces", id]))
  end
  defp maybe_add_path(ws), do: ws

  defp maybe_add_is_main(%{is_main: _} = ws), do: ws
  defp maybe_add_is_main(ws), do: Map.put(ws, :is_main, false)
end
