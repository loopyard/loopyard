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

    children = [
      {BoomLooper.Workspace.ServiceManager, project_dir: project_dir},
      {DynamicSupervisor, name: agent_sup_name(workspace_id), strategy: :one_for_one},
      {BoomLooper.ContainerMonitor, project_dir: project_dir}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  @doc "Start a ChatAgent under this workspace's agent supervisor."
  def start_agent(workspace_id, agent_opts) do
    case agent_sup_pid(workspace_id) do
      nil -> {:error, :workspace_not_running}
      _pid -> DynamicSupervisor.start_child(agent_sup_name(workspace_id), {BoomLooper.ChatAgent, agent_opts})
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
