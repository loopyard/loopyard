defmodule BoomLooper.BranchSupervisor do
  @moduledoc """
  Top-level DynamicSupervisor that holds all branch subtrees.
  Each branch gets its own Supervisor with ServiceManager + AgentSupervisor.
  """
  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc "Start a branch subtree. Returns {:ok, pid} or {:error, reason}."
  def start_branch(branch_id, project_dir) do
    case BoomLooper.Branch.whereis(branch_id) do
      nil ->
        DynamicSupervisor.start_child(__MODULE__,
          {BoomLooper.Branch, branch_id: branch_id, project_dir: project_dir})

      _pid ->
        {:ok, :already_running}
    end
  end

  @doc "Stop a branch subtree. Cascades to ServiceManager (Docker cleanup) and all agents."
  def stop_branch(branch_id) do
    case BoomLooper.Branch.whereis(branch_id) do
      nil -> {:error, :not_found}
      pid -> Supervisor.stop(pid, :normal, 15_000)
    end
  end

  @doc "Check if a branch is running."
  def branch_running?(branch_id) do
    BoomLooper.Branch.whereis(branch_id) != nil
  end
end
