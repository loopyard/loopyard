defmodule BoomLooper.WorkspaceSupervisor do
  @moduledoc """
  Top-level DynamicSupervisor that holds all workspace subtrees.
  Each workspace gets its own Supervisor with ServiceManager + AgentSupervisor.
  """
  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc "Start a workspace subtree. Returns {:ok, pid} or {:error, reason}."
  def start_workspace(workspace_id, project_dir) do
    case BoomLooper.WorkspaceGroup.whereis(workspace_id) do
      nil ->
        DynamicSupervisor.start_child(__MODULE__,
          {BoomLooper.WorkspaceGroup, workspace_id: workspace_id, project_dir: project_dir})

      _pid ->
        {:ok, :already_running}
    end
  end

  @doc """
  Stop a workspace subtree. ServiceManager.terminate/2 tears down Docker containers
  automatically, so this always does a full cleanup. No zombie containers possible.
  """
  def stop_workspace(workspace_id) do
    case BoomLooper.WorkspaceGroup.whereis(workspace_id) do
      nil -> {:error, :not_found}
      pid ->
        DynamicSupervisor.terminate_child(__MODULE__, pid)
        :ok
    end
  end

  @doc "Check if a workspace is running."
  def workspace_running?(workspace_id) do
    BoomLooper.WorkspaceGroup.whereis(workspace_id) != nil
  end
end
