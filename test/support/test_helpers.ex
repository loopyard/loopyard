defmodule BoomLooper.TestHelpers do
  @moduledoc "Shared helpers for tests that need workspace/agent infrastructure."

  @doc "Ensure a workspace subtree is running for a path. Returns the workspace_id."
  def ensure_workspace(path \\ File.cwd!()) do
    workspace_id = BoomLooper.Workspace.workspace_id(path)

    case BoomLooper.WorkspaceSupervisor.start_workspace(workspace_id, path) do
      {:ok, _} -> workspace_id
      {:error, {:already_started, _}} -> workspace_id

      # Nested `:already_started` arrives when the dynamic supervisor
      # itself is mid-start and a child (e.g. ServiceManager) claims
      # it's already registered. In the full-suite test run this shape
      # shows up when many test setups race on the same workspace_id.
      # Treat as "workspace is up, use it."
      {:error, {:shutdown, {:failed_to_start_child, _, {:already_started, _}}}} ->
        workspace_id
    end
  end

  @doc "Start an agent under the workspace for the given path."
  def start_agent(opts) do
    path = Keyword.get(opts, :working_dir, File.cwd!())
    workspace_id = ensure_workspace(path)
    start_agent_with_retry(workspace_id, opts, 3)
  end

  # Race: ensure_workspace can return :ok (subtree exists or was just
  # started) BEFORE the per-workspace `AgentDynamicSupervisor` is
  # fully registered. WorkspaceGroup.start_agent then returns
  # {:error, :workspace_not_running}. Brief retry bridges the gap so
  # test setup doesn't flake for unrelated timing reasons.
  defp start_agent_with_retry(_workspace_id, _opts, 0) do
    {:error, :workspace_not_running}
  end

  defp start_agent_with_retry(workspace_id, opts, attempts) do
    case BoomLooper.WorkspaceGroup.start_agent(workspace_id, opts) do
      {:error, :workspace_not_running} ->
        Process.sleep(50)
        start_agent_with_retry(workspace_id, opts, attempts - 1)

      result ->
        result
    end
  end
end
