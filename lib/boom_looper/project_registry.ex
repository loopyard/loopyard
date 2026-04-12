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

  @doc false
  def ensure_ets_tables, do: :ok

  # --- Projects ---

  @doc """
  Add a project from a git URL. Clones the repo into a volume and registers the workspace.
  Returns {:ok, project, workspace} or {:error, reason}.

  Options:
    - branch: branch to clone (default: "main")
    - token: GitHub token for auth (optional)
  """
  def add_from_url(git_url, opts \\ []) do
    branch = Keyword.get(opts, :branch, "main")
    token = Keyword.get(opts, :token)

    project_id = Workspace.project_id_from_git(git_url)
    workspace_id = Workspace.workspace_id_from_git(git_url, branch)

    # Find or create project
    project = case get_project(project_id) do
      nil ->
        name = unique_name(extract_repo_name(git_url), project_id)
        proj = %{
          id: project_id,
          name: name,
          git_url: git_url,
          is_git: true,
          volume_based: true,
          source_type: :github,
          source_config: %{git_url: git_url, branch: branch},
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
        # Compute path so all workspaces have the same shape
        computed_path = Path.join([Workspace.home_dir(), "workspaces", workspace_id])
        # First branch added is considered main (typically "main" or "master")
        existing_workspaces = list_workspaces(project_id)
        is_main = existing_workspaces == []

        ws = %{
          id: workspace_id,
          project_id: project_id,
          name: branch,
          branch: branch,
          git_url: git_url,
          volume: volume_name,
          volume_based: true,
          path: computed_path,
          is_main: is_main,
          status: :stopped,
          added_at: DateTime.utc_now()
        }
        :ets.insert(@workspaces_table, {workspace_id, ws})
        ws

      existing ->
        existing
    end

    # Clone code into volume if not already done
    # clone_mode: :sync (default), :disabled (tests)
    volume_name = BoomLooper.VolumeManager.code_volume_name(workspace_id)
    clone_mode = Application.get_env(:boom_looper, :clone_mode, :sync)

    clone_result =
      if clone_mode != :disabled and not BoomLooper.VolumeManager.volume_has_code?(volume_name) do
        BoomLooper.VolumeManager.clone_into_volume(volume_name, git_url, branch: branch, token: token)
      else
        {:ok, :skipped}
      end

    case clone_result do
      {:ok, _} ->
        # Persist to disk (store git_url instead of path)
        ProjectStore.add(git_url)
        {:ok, project, workspace}

      {:error, reason} ->
        # CRITICAL: Do NOT return {:ok, ...} with an empty volume. If we
        # did, the setup agent would start against an empty /workspace,
        # all its MCP tools would fail, and it would fall back to native
        # Claude Code filesystem tools (Read/Grep/Bash) which traverse
        # the HOST process cwd — which happens to be the BoomLooper repo
        # root. We'd get a bizarre false-success where the agent "sets
        # up" BoomLooper itself instead of the target project.
        # This was the chatwoot eval bug.
        Logger.error("[ProjectRegistry] Clone failed for #{git_url}: #{reason}")

        # Roll back the ETS entries we just inserted so a retry can re-create them.
        :ets.delete(@workspaces_table, workspace_id)
        :ets.delete(@projects_table, project_id)

        {:error, "Clone failed: #{reason}"}
    end
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
  Add a project from a directory path. Delegates project construction to
  the Local source adapter and handles ETS + ProjectStore persistence.
  Returns {:ok, project, workspace} or {:error, reason}.
  """
  def add(path) do
    case BoomLooper.Source.Local.add_project(path, []) do
      {:ok, built} ->
        project = upsert_project(built)

        # Register the current workspace. For a git repo we use the
        # current branch; otherwise "main".
        workspace_name =
          case Git.current_branch(project.path) do
            {:ok, branch} -> branch
            _ -> "main"
          end

        workspace = find_or_create_workspace(project.id, workspace_name, project.path)

        if project[:is_git] do
          discover_worktrees(project)
        end

        ProjectStore.add(project.path, source_type: :local)

        {:ok, project, workspace}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Insert-or-update: if the project already exists in ETS we preserve its
  # current name (users may have renamed it) and overlay any new
  # source_type / source_config from the adapter.
  defp upsert_project(built) do
    case get_project(built.id) do
      nil ->
        name = unique_name(built.name, built.id)
        project = Map.put(built, :name, name)
        :ets.insert(@projects_table, {project.id, project})
        project

      existing ->
        merged = Map.merge(built, %{name: existing.name})
        :ets.insert(@projects_table, {merged.id, merged})
        merged
    end
  end

  @doc """
  Rename a project. Updates ETS and persists to disk. Trims input.
  If the requested name collides with another project, appends a numeric
  suffix (e.g. `myapp-2`) so each project remains uniquely findable.
  """
  def rename_project(project_id, new_name) do
    name = String.trim(to_string(new_name || ""))

    cond do
      name == "" ->
        {:error, :empty_name}

      true ->
        case :ets.lookup(:project_registry, project_id) do
          [{_, project}] ->
            unique = unique_name(name, project_id)
            updated = Map.put(project, :name, unique)
            :ets.insert(:project_registry, {project_id, updated})
            persist_all_projects()
            {:ok, updated}

          [] ->
            {:error, :not_found}
        end
    end
  end

  # Names that the basename strategy commonly produces but tell you nothing.
  # When we hit one of these, walk up to the parent dir for something useful.
  @generic_basenames ~w(project src code app repo source main master trunk)

  @doc """
  Derive a human-readable default name from a directory path. Falls back to
  the parent directory when the basename is generic (e.g. "project", "src").
  Returns nil if nothing usable can be extracted.
  """
  def default_name_from_path(path) when is_binary(path) do
    parts =
      path
      |> Path.expand()
      |> Path.split()
      |> Enum.reverse()
      |> Enum.reject(&(&1 in ["", "/"]))

    Enum.find(parts, fn segment ->
      segment not in @generic_basenames and segment != "."
    end)
  end
  def default_name_from_path(_), do: nil

  # Returns a name unique across all projects, except for the project we're
  # naming (so renaming a project to its own current name is a no-op).
  defp unique_name(base, exclude_id) do
    taken =
      list_projects()
      |> Enum.reject(&(&1.id == exclude_id))
      |> MapSet.new(& &1.name)

    if MapSet.member?(taken, base) do
      Stream.iterate(2, &(&1 + 1))
      |> Enum.find_value(fn n ->
        candidate = "#{base}-#{n}"
        if MapSet.member?(taken, candidate), do: nil, else: candidate
      end)
    else
      base
    end
  end

  defp persist_all_projects do
    projects = list_projects()
    # `path` in the persisted store is overloaded — it's either a filesystem
    # path (bind-mount projects) or a git URL (volume-based projects). Use
    # whichever key the project actually has so the rename round-trips.
    records =
      projects
      |> Enum.map(fn p ->
        %{
          path: p[:path] || p[:git_url],
          name: p.name,
          source_type: p[:source_type]
        }
      end)
      |> Enum.reject(&is_nil(&1.path))

    ProjectStore.save(records)
  end

  @doc """
  Restore projects from disk on startup.

  Re-registers all projects from `~/.boomlooper/projects.json`.
  ServiceManager will detect running containers and reconnect.
  """
  def restore do
    for entry <- ProjectStore.load() do
      # Handle both old format (string path) and new format (map with path/name)
      {path, saved_name} = case entry do
        %{path: p, name: n} -> {p, n}
        %{path: p} -> {p, nil}
        p when is_binary(p) -> {p, nil}
      end

      result = cond do
        # Git URL (volume-based)
        String.starts_with?(path, "git@") or String.starts_with?(path, "https://") ->
          add_from_url(path)

        # Local path (bind-mount based)
        true ->
          add(path)
      end

      case result do
        {:ok, project, _workspace} ->
          # Apply saved name if present and not generic; otherwise upgrade
          # generic/missing names using the directory layout.
          desired = cond do
            is_binary(saved_name) and String.trim(saved_name) != "" and saved_name not in @generic_basenames ->
              saved_name
            is_binary(project[:path]) ->
              default_name_from_path(project[:path]) || project.name
            true ->
              project.name
          end

          unique = unique_name(desired, project.id)
          if unique != project.name do
            :ets.insert(:project_registry, {project.id, Map.put(project, :name, unique)})
          end
          :ok

        {:error, reason} ->
          Logger.warning("[ProjectRegistry] Failed to restore project #{path}: #{reason}")
      end
    end

    # Persist normalized names so they survive the next restart without recomputation.
    persist_all_projects()

    :ok
  end

  @doc "List all projects."
  def list_projects do
    :ets.tab2list(@projects_table)
    |> Enum.map(fn {_id, project} -> project end)
    |> Enum.sort_by(& &1.name)
  end

  @doc "Get a project by ID."
  def get_project(id) do
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
    project = get_project(id)
    workspaces = list_workspaces(id)

    # Stop all agents and clean up ETS entries
    all_agents = BoomLooper.ChatAgent.list_agents()

    adapter = BoomLooper.Source.for_project(project || %{})

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

      # Let the Source adapter clean up adapter-specific state (e.g.
      # Local: terminate mutagen session, remove host worktree).
      adapter.remove_workspace(project || %{}, workspace)
    end)

    if project do
      # Remove from disk persistence
      persistence_key = project[:git_url] || project[:path]
      ProjectStore.remove(persistence_key)

      # Delete .boomlooper directory synchronously (fast local operation)
      unless project[:volume_based] do
        boomlooper_dir = Path.join(project.path, ".boomlooper")
        File.rm_rf(boomlooper_dir)
      end

      # CRITICAL: also wipe the host-side virtual workspace dir.
      # `agents.log` lives at ~/.boomlooper/workspaces/<ws_id>/.boomlooper/workspace/agents.log
      # — that's a HOST path, not a Docker volume. If we leave it behind,
      # the next eval that re-clones the same git URL gets the SAME
      # workspace_id (deterministic), and ServiceManager.init replays the
      # leftover log, resurrecting ghost agents from the previous run.
      # This was the cause of the "two Setup agents" bug.
      Enum.each(workspaces, fn ws ->
        virtual_dir = Path.join([Workspace.home_dir(), "workspaces", ws.id])
        File.rm_rf(virtual_dir)
      end)

      # Clean up volumes and compose resources synchronously. This used to
      # run in a background Task, but fire-and-forget cleanup caused volume
      # leaks — failures were silently swallowed and the caller (eval runner)
      # would race the cleanup with the next workspace creation.
      Enum.each(workspaces, fn ws ->
        try do
          ws_id = ws.id
          virtual_dir = Path.join([Workspace.home_dir(), "workspaces", ws_id])
          BoomLooper.Compose.down_volumes(virtual_dir, ws_id)

          # Delete code + cache volumes (always, not just volume_based)
          BoomLooper.VolumeManager.delete_volume(BoomLooper.VolumeManager.code_volume_name(ws_id))
          BoomLooper.VolumeManager.delete_volume(BoomLooper.VolumeManager.cache_volume_name(ws_id))

          # Also try the old naming convention in case any legacy volumes exist
          BoomLooper.VolumeManager.delete_volume("code-#{ws_id}")
        rescue
          _ -> :ok
        catch
          _, _ -> :ok
        end
      end)
    end

    # Remove from ETS
    Enum.each(workspaces, fn ws -> :ets.delete(@workspaces_table, ws.id) end)
    :ets.delete(@projects_table, id)
    :ok
  end

  # --- Workspaces ---

  @doc "List workspaces for a project."
  def list_workspaces(project_id) do
    :ets.tab2list(@workspaces_table)
    |> Enum.map(fn {_id, workspace} -> normalize_workspace(workspace) end)
    |> Enum.filter(&(&1.project_id == project_id))
    |> Enum.sort_by(fn w -> if w.name == "main", do: "0", else: w.name end)
  end

  @doc "Get a workspace by ID."
  def get_workspace(id) do
    case :ets.lookup(@workspaces_table, id) do
      [{^id, workspace}] -> normalize_workspace(workspace)
      [] -> nil
    end
  end

  # Ensure all workspaces have consistent shape (path, is_main)
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

  @doc """
  Add a new workspace to a project. Delegates to the project's Source adapter.
  Returns {:ok, workspace} or {:error, reason}.
  """
  def add_workspace(project_id, branch_name) do
    project = get_project(project_id)

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
        project = get_project(workspace.project_id)
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

  # --- Private ---

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

    # For Local projects, the main workspace's worktree path IS the host
    # repo itself — mutagen syncs the host repo directly with the volume.
    # Branch workspaces get their own worktree created by the adapter.
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
