defmodule BoomLooper.WorkspaceGroup do
  @moduledoc """
  Per-workspace Supervisor. Each workspace gets a ServiceManager and a DynamicSupervisor for agents.
  Strategy is :one_for_all — if ServiceManager dies, agents restart too (they need containers).
  """
  use Supervisor

  @registry BoomLooper.WorkspaceRegistry
  @agent_registry BoomLooper.WorkspaceAgentRegistry

  def start_link(opts) do
    workspace_id = Keyword.fetch!(opts, :workspace_id)
    Supervisor.start_link(__MODULE__, opts, name: via(workspace_id))
  end

  @impl true
  def init(opts) do
    workspace_id = Keyword.fetch!(opts, :workspace_id)
    project_dir = Keyword.fetch!(opts, :project_dir)

    base_children = [
      {BoomLooper.Workspace.ServiceManager, project_dir: project_dir, workspace_id: workspace_id},
      {DynamicSupervisor, name: agent_sup_name(workspace_id), strategy: :one_for_one},
      # RestartController owns every agent respawn decision. Must
      # start after the agent DynamicSupervisor (it calls
      # start_child against it) and before ContainerMonitor
      # (doesn't matter but keeps related things adjacent).
      {BoomLooper.ChatAgent.RestartController, workspace_id: workspace_id},
      {BoomLooper.ContainerMonitor, project_dir: project_dir, workspace_id: workspace_id},
      # Checkpointer owns the agent-log snapshot schedule. One per
      # workspace so a broken snapshot on workspace A can't block
      # snapshots on workspace B. Move #8.
      checkpointer_child_spec(workspace_id)
    ]

    children = base_children ++ source_children(workspace_id)

    # Give Docker operations time to recover — default 3/5s is too tight for I/O
    Supervisor.init(children, strategy: :one_for_all, max_restarts: 10, max_seconds: 60)
  end

  # Agent-log checkpointer spec. Resolves the log path the same way
  # `BoomLooper.ChatAgent.Persistence` does, and uses `via/1` so the
  # checkpointer is looked up by workspace_id from anywhere (e.g. the
  # `/system/recovery` page).
  defp checkpointer_child_spec(workspace_id) do
    log_path =
      Path.join([
        BoomLooper.Workspace.compose_dir(workspace_id),
        ".boomlooper",
        "workspace",
        "agents.log"
      ])

    {BoomLooper.AgentLog.Checkpointer,
     [
       workspace_id: workspace_id,
       log_path: log_path,
       version: 1,
       name: BoomLooper.AgentLog.Checkpointer.via(workspace_id)
     ]}
  end

  # Source-specific children (e.g. Local workspaces get a SyncMonitor that
  # owns the mutagen session). Looked up via the ETS registry so adapters
  # stay decoupled from the supervisor tree.
  defp source_children(workspace_id) do
    with %{project_id: project_id} = workspace <-
           BoomLooper.ProjectRegistry.get_workspace(workspace_id),
         %{source_type: :local} <- BoomLooper.ProjectRegistry.get_project(project_id) do
      worktree_path =
        workspace[:worktree_path] ||
          BoomLooper.Source.Local.Worktree.path_for(workspace_id)

      [
        {BoomLooper.Source.Local.SyncMonitor,
         workspace_id: workspace_id, worktree_path: worktree_path}
      ]
    else
      _ -> []
    end
  end

  @doc """
  Start a ChatAgent under this workspace.

  Routes through `BoomLooper.ChatAgent.RestartController` so crash
  tracking + quarantine are enforced from the first spawn. Returns
  `{:error, :quarantined}` if the agent id is currently in
  quarantine (operator must `release/1` first).
  """
  def start_agent(workspace_id, agent_opts) do
    case agent_sup_pid(workspace_id) do
      nil -> {:error, :workspace_not_running}
      _pid -> BoomLooper.ChatAgent.RestartController.start_agent(workspace_id, agent_opts)
    end
  end

  @doc "Look up the pid for a workspace supervisor."
  def whereis(workspace_id) do
    case Registry.lookup(@registry, workspace_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "The registered name of the per-workspace agent DynamicSupervisor."
  def agent_sup_name(workspace_id) do
    {:via, Registry, {@agent_registry, workspace_id}}
  end

  defp agent_sup_pid(workspace_id) do
    case Registry.lookup(@agent_registry, workspace_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp via(workspace_id) do
    {:via, Registry, {@registry, workspace_id}}
  end
end
