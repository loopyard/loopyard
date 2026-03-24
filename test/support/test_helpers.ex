defmodule BoomLooper.TestHelpers do
  @moduledoc "Shared helpers for tests that need workspace/agent infrastructure."

  @doc "Ensure a workspace subtree is running for a path. Returns the workspace_id."
  def ensure_workspace(path \\ File.cwd!()) do
    workspace_id = BoomLooper.Workspace.workspace_id(path)

    case BoomLooper.WorkspaceSupervisor.start_workspace(workspace_id, path) do
      {:ok, _} -> workspace_id
      {:error, {:already_started, _}} -> workspace_id
    end
  end

  @doc "Start an agent under the workspace for the given path."
  def start_agent(opts) do
    path = Keyword.get(opts, :working_dir, File.cwd!())
    workspace_id = ensure_workspace(path)
    BoomLooper.WorkspaceGroup.start_agent(workspace_id, opts)
  end
end
