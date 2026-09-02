defmodule Loopyard.WorkspaceRegistry do
  @moduledoc """
  Registry of workspaces (worktrees) within projects.
  Each workspace has its own containers, volumes, and agents.
  Stored in ETS for fast access.
  """

  alias Loopyard.Workspace

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
    # Access, not dot: a minimal/malformed row (fabricated test rows, partial
    # writes) must never crash EVERY reader of the registry.
    |> Enum.filter(&(&1[:project_id] == project_id))
    |> Enum.sort_by(fn w -> if w[:name] == "main", do: "0", else: w[:name] end)
  end

  @doc """
  Add a new workspace to a project.

  Two phases — synchronous prepare + async setup saga:

    1. **Synchronous, instant**. Adapter's `prepare_workspace/3` builds
       the workspace map (workspace_id, paths, volume name) — NO I/O,
       NO Docker, NO filesystem. The result is inserted into ETS at
       `setup.phase: :pending` and returned to the caller.

    2. **Asynchronous**. `Workspace.Setup.start/1` spawns a saga task
       that runs three phases in order — `:worktree`, `:volume`,
       `:seeding`. Each phase is idempotent (safe to re-run via Retry).
       PubSub events drive the SetupProgress LiveView UI.

  By the time this function returns, the workspace is **visible** in
  the UI but **not yet usable** for cluster start / agent boot — those
  are gated on `Workspace.ready?/1`. The user sees a "Setting up
  workspace…" step list until the saga finishes.

  GitHub workspaces today are still populated by the legacy synchronous
  clone in `ProjectRegistry.add_from_url`; PR2 routes them through this
  saga.
  """
  def add_workspace(project_id, branch_name) do
    project = Loopyard.ProjectRegistry.get_project(project_id)

    if project do
      existing = list_workspaces(project_id) |> Enum.find(&(&1.name == branch_name))

      if existing do
        {:ok, existing}
      else
        adapter = Loopyard.Source.for_project(project)

        case adapter.prepare_workspace(project, branch_name, []) do
          {:ok, workspace} ->
            workspace = ensure_setup_field(workspace)
            :ets.insert(@workspaces_table, {workspace.id, workspace})
            Loopyard.Workspace.Setup.start(workspace.id)
            {:ok, workspace}

          {:error, reason} ->
            {:error, reason}
        end
      end
    else
      {:error, "Project not found"}
    end
  end

  @doc """
  Merge `changes` into the workspace's `:setup` field. Used by
  `Loopyard.Workspace.Setup` as the saga progresses. No-op (returns
  `{:error, :not_found}`) if the workspace isn't in ETS.
  """
  def update_setup(workspace_id, changes) when is_map(changes) do
    case :ets.lookup(@workspaces_table, workspace_id) do
      [{^workspace_id, workspace}] ->
        current_setup =
          Map.get(workspace, :setup, Loopyard.Workspace.Setup.initial_setup_field())

        new_setup = Map.merge(current_setup, changes)
        updated = Map.put(workspace, :setup, new_setup)
        :ets.insert(@workspaces_table, {workspace_id, updated})
        {:ok, updated}

      [] ->
        {:error, :not_found}
    end
  end

  defp ensure_setup_field(workspace) do
    case Map.get(workspace, :setup) do
      nil -> Map.put(workspace, :setup, Loopyard.Workspace.Setup.initial_setup_field())
      _ -> workspace
    end
  end

  @doc """
  Remove a workspace. Routes through `Workspace.Destructor.destroy/1`
  which stops agents, tears down containers/networks/volumes, runs the
  source adapter's teardown, removes the compose dir on the host, and
  clears ETS. Idempotent — safe to re-run on a partially-destroyed
  workspace. Cannot remove the main workspace.
  """
  def remove_workspace(workspace_id) do
    workspace = get_workspace(workspace_id)

    cond do
      is_nil(workspace) ->
        {:error, "Workspace not found"}

      workspace.is_main ->
        {:error, "Cannot remove the main workspace"}

      true ->
        # Revoke the MCP bridge tokens of every agent in this workspace before
        # tearing it down — the workspace is gone, so leaked tokens must stop
        # working (issue #81).
        for agent <- Loopyard.ChatAgent.list_agents_for_workspace(workspace_id) do
          Loopyard.MCP.Token.revoke(agent.id)
        end

        Loopyard.Workspace.Destructor.destroy(workspace_id)
    end
  end

  @doc "Update workspace status (e.g. :running, :stopped)."
  def update_workspace_status(workspace_id, status) do
    case :ets.lookup(@workspaces_table, workspace_id) do
      [{^workspace_id, workspace}] ->
        updated = %{workspace | status: status}
        :ets.insert(@workspaces_table, {workspace_id, updated})
        publish_change(updated[:project_id], :status, workspace_id)
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
    result = :ets.insert(@workspaces_table, {workspace_id, workspace})
    publish_change(workspace[:project_id], :created, workspace_id)
    result
  end

  @doc false
  def delete(workspace_id) do
    project_id =
      case :ets.lookup(@workspaces_table, workspace_id) do
        [{^workspace_id, ws}] -> ws[:project_id]
        _ -> nil
      end

    result = :ets.delete(@workspaces_table, workspace_id)
    publish_change(project_id, :removed, workspace_id)
    result
  end

  # --- Private ---

  # Nudge the project's workspace-list subscribers (switcher + project grid) to
  # reload. project_id can be nil for legacy/path-based workspaces — skip then.
  defp publish_change(nil, _action, _workspace_id), do: :ok

  defp publish_change(project_id, action, workspace_id) do
    Loopyard.Events.Workspaces.publish(%Loopyard.Events.Workspaces.Changed{
      project_id: project_id,
      action: action,
      workspace_id: workspace_id
    })
  end

  defp create_workspace(project_id, workspace_name, path) do
    project = Loopyard.ProjectRegistry.get_project(project_id)
    is_main = path == project.path
    id = workspace_id(path)

    workspace = %{
      id: id,
      project_id: project_id,
      name: workspace_name,
      path: path,
      branch: workspace_name,
      is_main: is_main,
      status: :stopped,
      added_at: DateTime.utc_now()
    }

    # normalize_workspace backfills worktree_path from path for Local
    # workspaces, so we don't need to set it explicitly here.
    workspace = normalize_workspace(workspace)
    :ets.insert(@workspaces_table, {id, workspace})
    workspace
  end

  defp normalize_workspace(ws) do
    ws
    |> maybe_add_path()
    |> maybe_add_is_main()
    |> maybe_add_worktree_path()
    |> maybe_add_compose_dir()
    |> maybe_add_setup()
  end

  # Backfill the setup field for workspaces persisted before this feature
  # shipped. They were always synchronous-success on the old code path,
  # so they're definitionally :ready.
  defp maybe_add_setup(%{setup: %{phase: _}} = ws), do: ws

  defp maybe_add_setup(ws) do
    Map.put(ws, :setup, Loopyard.Workspace.Setup.ready_setup_field())
  end

  defp maybe_add_path(%{path: _} = ws), do: ws

  defp maybe_add_path(%{volume_based: true, id: id} = ws) do
    Map.put(ws, :path, Path.join([Workspace.home_dir(), "workspaces", id]))
  end

  defp maybe_add_path(ws), do: ws

  defp maybe_add_is_main(%{is_main: _} = ws), do: ws
  defp maybe_add_is_main(ws), do: Map.put(ws, :is_main, false)

  # Backfill worktree_path for pre-refactor Local workspaces. The rule:
  # if worktree_path is nil and path points to a real host directory
  # (not a virtual workspace dir under LOOPYARD_HOME/workspaces/),
  # the path IS the worktree — set it. This is the single source of
  # truth for "where should Mutagen sync to."
  defp maybe_add_worktree_path(%{worktree_path: path} = ws) when is_binary(path), do: ws

  defp maybe_add_worktree_path(%{path: path} = ws) when is_binary(path) do
    virtual_prefix = Path.join(Workspace.home_dir(), "workspaces")

    if String.starts_with?(path, virtual_prefix) do
      ws
    else
      Map.put(ws, :worktree_path, path)
    end
  end

  defp maybe_add_worktree_path(ws), do: ws

  # The compose file always lives in the virtual workspace dir, never in
  # the host project dir. This is the single source of truth for "where
  # does ServiceManager read/write compose files." Every consumer —
  # sidebar, service status, tools — reads from workspace.compose_dir
  # instead of computing the path ad-hoc.
  defp maybe_add_compose_dir(%{compose_dir: dir} = ws) when is_binary(dir), do: ws

  defp maybe_add_compose_dir(%{id: id} = ws) do
    Map.put(ws, :compose_dir, Path.join([Workspace.home_dir(), "workspaces", id]))
  end

  defp maybe_add_compose_dir(ws), do: ws
end
