defmodule BoomLooper.TestHelpers do
  @moduledoc "Shared helpers for tests that need branch/agent infrastructure."

  @doc "Ensure a branch subtree is running for a path. Returns the branch_id."
  def ensure_branch(path \\ File.cwd!()) do
    branch_id = BoomLooper.Workspace.workspace_id(path)

    case BoomLooper.BranchSupervisor.start_branch(branch_id, path) do
      {:ok, _} -> branch_id
      {:ok, :already_running} -> branch_id
      {:error, {:already_started, _}} -> branch_id
    end
  end

  @doc "Start an agent under the branch for the given path."
  def start_agent(opts) do
    path = Keyword.get(opts, :working_dir, File.cwd!())
    branch_id = ensure_branch(path)
    BoomLooper.Branch.start_agent(branch_id, opts)
  end
end
