defmodule BoomLooper.Branch do
  @moduledoc """
  Per-branch Supervisor. Each branch gets a ServiceManager and a DynamicSupervisor for agents.
  Strategy is :one_for_all — if ServiceManager dies, agents restart too (they need containers).
  """
  use Supervisor

  @registry BoomLooper.BranchRegistry
  @agent_registry BoomLooper.BranchAgentRegistry

  def start_link(opts) do
    branch_id = Keyword.fetch!(opts, :branch_id)
    Supervisor.start_link(__MODULE__, opts, name: via(branch_id))
  end

  @impl true
  def init(opts) do
    branch_id = Keyword.fetch!(opts, :branch_id)
    project_dir = Keyword.fetch!(opts, :project_dir)

    children = [
      {BoomLooper.Workspace.ServiceManager, project_dir: project_dir},
      {DynamicSupervisor, name: agent_sup_name(branch_id), strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  @doc "Start a ChatAgent under this branch's agent supervisor."
  def start_agent(branch_id, agent_opts) do
    case agent_sup_pid(branch_id) do
      nil -> {:error, :branch_not_running}
      _pid -> DynamicSupervisor.start_child(agent_sup_name(branch_id), {BoomLooper.ChatAgent, agent_opts})
    end
  end

  @doc "Look up the pid for a branch supervisor."
  def whereis(branch_id) do
    case Registry.lookup(@registry, branch_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "The registered name of the per-branch agent DynamicSupervisor."
  def agent_sup_name(branch_id) do
    {:via, Registry, {@agent_registry, branch_id}}
  end

  defp agent_sup_pid(branch_id) do
    case Registry.lookup(@agent_registry, branch_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp via(branch_id) do
    {:via, Registry, {@registry, branch_id}}
  end
end
