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
    workspace_id = ensure_workspace_ready(path)
    start_agent_with_retry(workspace_id, opts, 60)
  end

  # Under full-suite load many tests share the cwd-derived workspace_id
  # and the per-workspace group churns: ServiceManager async_init
  # exits with :noproc, max_restarts hits, WorkspaceSupervisor rebuilds
  # the group via the saga. During the rebuild window the agent
  # DynamicSupervisor AND the RestartController are both
  # unregistered. wait_for_workspace_ready blocks until both come back.
  # If we still time out, redrive ensure_workspace once — it may have
  # been torn down between our wait and our retry.
  defp ensure_workspace_ready(path) do
    workspace_id = ensure_workspace(path)

    case wait_for_workspace_ready(workspace_id, 100) do
      :ok ->
        workspace_id

      :timeout ->
        # Force a fresh start if the group is wedged.
        workspace_id = ensure_workspace(path)
        _ = wait_for_workspace_ready(workspace_id, 100)
        workspace_id
    end
  end

  defp wait_for_workspace_ready(_workspace_id, 0), do: :timeout

  defp wait_for_workspace_ready(workspace_id, attempts) do
    agent_sup =
      Registry.lookup(BoomLooper.WorkspaceAgentRegistry, workspace_id) != []

    restart_ctrl =
      Registry.lookup(BoomLooper.ChatAgent.RestartControllerRegistry, workspace_id) != []

    if agent_sup and restart_ctrl do
      :ok
    else
      Process.sleep(50)
      wait_for_workspace_ready(workspace_id, attempts - 1)
    end
  end

  defp start_agent_with_retry(_workspace_id, _opts, 0) do
    {:error, :workspace_not_running}
  end

  defp start_agent_with_retry(workspace_id, opts, attempts) do
    case BoomLooper.WorkspaceGroup.start_agent(workspace_id, opts) do
      {:error, :workspace_not_running} ->
        Process.sleep(100)
        start_agent_with_retry(workspace_id, opts, attempts - 1)

      result ->
        result
    end
  end
end
