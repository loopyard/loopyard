defmodule Loopyard.TestHelpers do
  @moduledoc "Shared helpers for tests that need workspace/agent infrastructure."

  @doc """
  Full teardown for a test-created workspace — the cleanup tests should run in
  `on_exit` instead of a bare `stop_workspace/1`. Stops the supervisor subtree
  AND removes the workspace's Docker containers + volumes via the real
  `Workspace.Destructor`, so a test doesn't leak `loopyard-<id>-*` volumes across
  runs (which is what let the dev volume count balloon to 10k+).

  SAFETY: refuses to delete volumes for the shared cwd-derived workspace — that
  id is reused by many tests and its `loopyard-<id>-code` volume may be a real
  one. For that id it only stops the subtree. Isolate a test on its own temp
  dir (unique id) if it needs its volumes actually cleaned.
  """
  def destroy_workspace(workspace_id) do
    if workspace_id == Loopyard.Workspace.workspace_id(File.cwd!()) do
      Loopyard.WorkspaceSupervisor.stop_workspace(workspace_id)
    else
      Loopyard.WorkspaceSupervisor.stop_workspace(workspace_id)
      Loopyard.Workspace.Destructor.destroy(workspace_id)
    end

    :ok
  end

  @doc "Ensure a workspace subtree is running for a path. Returns the workspace_id."
  def ensure_workspace(path \\ File.cwd!()) do
    workspace_id = Loopyard.Workspace.workspace_id(path)

    case Loopyard.WorkspaceSupervisor.start_workspace(workspace_id, path) do
      {:ok, _} ->
        :ok

      {:error, {:already_started, _}} ->
        :ok

      # Nested `:already_started` arrives when the dynamic supervisor
      # itself is mid-start and a child (e.g. ServiceManager) claims
      # it's already registered. In the full-suite test run this shape
      # shows up when many test setups race on the same workspace_id.
      # Treat as "workspace is up, use it."
      {:error, {:shutdown, {:failed_to_start_child, _, {:already_started, _}}}} ->
        :ok
    end

    register_workspace_cleanup(workspace_id)
    workspace_id
  end

  # Tidy up after the test: schedule teardown (subtree + Docker containers +
  # volumes) of any NON-cwd workspace a test spins up through here, once per id.
  # The shared cwd workspace is never auto-destroyed — its -code volume may be a
  # real one; see destroy_workspace/1. This is what keeps tests from leaking
  # `loopyard-<id>-*` volumes regardless of whether they used the default or an
  # explicit :working_dir.
  defp register_workspace_cleanup(workspace_id) do
    cwd_id = Loopyard.Workspace.workspace_id(File.cwd!())
    seen = Process.get(:loopyard_test_cleanup_wids, MapSet.new())
    # A module-owned workspace (Loopyard.AgentCase) is torn down by the module.
    module_owned = Process.get(:loopyard_test_module_workspace_id)

    if workspace_id != cwd_id and workspace_id != module_owned and
         not MapSet.member?(seen, workspace_id) do
      Process.put(:loopyard_test_cleanup_wids, MapSet.put(seen, workspace_id))
      ExUnit.Callbacks.on_exit(fn -> destroy_workspace(workspace_id) end)
    end

    :ok
  end

  @doc """
  Start an agent under a workspace. When no `:working_dir` is given, the agent
  runs in a UNIQUE per-test temp workspace (auto-created, auto-destroyed on
  exit) instead of the shared `File.cwd!()` one — so tests don't churn/pollute
  each other's workspace group and don't leak volumes. Pass `:working_dir`
  explicitly if a test needs a specific path.
  """
  def start_agent(opts) do
    path = Keyword.get_lazy(opts, :working_dir, &test_workspace_path/0)
    # Thread the resolved path back so the agent and the workspace we started
    # agree on the same dir (the agent reads working_dir from opts).
    opts = Keyword.put(opts, :working_dir, path)
    workspace_id = ensure_workspace_ready(path)
    start_agent_with_retry(workspace_id, opts, 240)
  end

  # One isolated temp workspace DIR per TEST (memoized in the test process's
  # dictionary). Reused by later start_agent/0 calls in the same test so agents
  # that should share a workspace still do. Workspace/volume teardown is
  # registered by ensure_workspace/1; here we just reap the temp dir itself.
  defp test_workspace_path do
    case Process.get(:loopyard_test_workspace_path) do
      nil ->
        path =
          Path.join(System.tmp_dir!(), "loopyard-test-ws-#{System.unique_integer([:positive])}")

        File.mkdir_p!(path)
        Process.put(:loopyard_test_workspace_path, path)
        ExUnit.Callbacks.on_exit(fn -> File.rm_rf(path) end)
        path

      path ->
        path
    end
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

    case wait_for_workspace_ready(workspace_id, 500) do
      :ok ->
        workspace_id

      :timeout ->
        # Force a fresh start if the group is wedged.
        workspace_id = ensure_workspace(path)
        _ = wait_for_workspace_ready(workspace_id, 500)
        workspace_id
    end
  end

  defp wait_for_workspace_ready(_workspace_id, 0), do: :timeout

  defp wait_for_workspace_ready(workspace_id, attempts) do
    agent_sup =
      Registry.lookup(Loopyard.WorkspaceAgentRegistry, workspace_id) != []

    restart_ctrl =
      Registry.lookup(Loopyard.ChatAgent.RestartControllerRegistry, workspace_id) != []

    if agent_sup and restart_ctrl do
      :ok
    else
      # 10ms polls: the group is usually up within a few, and every agent test
      # pays this wait — 50ms polls were a hidden floor on ~150 boots.
      Process.sleep(10)
      wait_for_workspace_ready(workspace_id, attempts - 1)
    end
  end

  defp start_agent_with_retry(_workspace_id, _opts, 0) do
    {:error, :workspace_not_running}
  end

  defp start_agent_with_retry(workspace_id, opts, attempts) do
    case Loopyard.WorkspaceGroup.start_agent(workspace_id, opts) do
      {:error, :workspace_not_running} ->
        Process.sleep(25)
        start_agent_with_retry(workspace_id, opts, attempts - 1)

      result ->
        result
    end
  end
end
