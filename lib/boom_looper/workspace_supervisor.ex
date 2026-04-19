defmodule BoomLooper.WorkspaceSupervisor do
  @moduledoc """
  Top-level DynamicSupervisor that holds all workspace subtrees.
  Each workspace gets its own Supervisor with ServiceManager + AgentSupervisor.

  ## Saga-wrapped start (Move #7a)

  `start_workspace/2` runs as a `BoomLooper.Saga` when it needs to
  rebuild an unhealthy group. The saga makes the stop-then-start
  sequence atomic: if the `start_child` fails after the stop,
  rollback is a no-op (we couldn't bring the old group back anyway,
  and the stop is not reversible), but `/system/sagas` surfaces the
  failed step with the underlying reason so the operator knows the
  workspace is down. In the common no-rebuild case (group missing
  OR healthy) we skip the saga ceremony — there's only one step.
  """
  use DynamicSupervisor

  alias BoomLooper.Saga

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
        start_child(workspace_id, project_dir)

      _pid ->
        # WorkspaceGroup exists — but its ServiceManager child might
        # be dead (transient restart, max_restarts hit, etc.). In that
        # state, `workspace_running?` returns true, `:boot_workspace`
        # shorts out with `:already_running`, and compose up never
        # fires — the LV pins at `:starting` forever. Verify the
        # essential child is alive; if not, tear the whole group down
        # and start fresh so users don't have to RPC in to unstick.
        if healthy_group?(workspace_id) do
          {:ok, :already_running}
        else
          require Logger

          Logger.warning(
            "[WorkspaceSupervisor] #{workspace_id} group alive but ServiceManager missing; restarting group"
          )

          rebuild_saga(workspace_id, project_dir)
        end
    end
  end

  defp start_child(workspace_id, project_dir) do
    DynamicSupervisor.start_child(
      __MODULE__,
      {BoomLooper.WorkspaceGroup, workspace_id: workspace_id, project_dir: project_dir}
    )
  end

  # The two-step rebuild flow: stop the unhealthy group, then start
  # a fresh one. Step 1 (stop) has no rollback — we can't un-stop
  # a supervisor, and the reason we stopped it is that it was
  # already unhealthy. Step 2 (start) has no rollback either: if
  # the start fails we just return the error to the caller. The
  # saga wrapping buys us telemetry + `/system/sagas` visibility
  # for this otherwise-invisible multi-step transaction.
  defp rebuild_saga(workspace_id, project_dir) do
    steps = [
      %{
        name: :stop_unhealthy_group,
        run: fn _ctx ->
          stop_workspace(workspace_id)
          {:ok, %{}}
        end
      },
      %{
        name: :start_fresh_group,
        run: fn _ctx ->
          case start_child(workspace_id, project_dir) do
            {:ok, pid} -> {:ok, %{pid: pid}}
            {:error, reason} -> {:error, reason}
          end
        end
      }
    ]

    case Saga.run(steps,
           name: :rebuild_workspace,
           metadata: %{workspace_id: workspace_id},
           # Rebuild steps aren't safely idempotent across a BEAM
           # crash: step 1 terminates the old group via
           # DynamicSupervisor; on a crashed-mid-rebuild resume the
           # old group is already gone (normal supervisor restart
           # brought nothing back), and a forward-resume would try
           # to start_child for a workspace whose prior state we
           # can't reason about. Rolling back — which here is a
           # no-op because neither step declares a rollback — at
           # least surfaces the incident in /system/sagas so the
           # operator knows to retry.
           on_resume: :rollback
         ) do
      {:ok, %{pid: pid}} -> {:ok, pid}
      {:error, {:step_failed, _step, reason}, _} -> {:error, reason}
    end
  end

  defp healthy_group?(workspace_id) do
    compose_dir = BoomLooper.Workspace.compose_dir(workspace_id)

    case Registry.lookup(BoomLooper.ServiceManagerRegistry, compose_dir) do
      [{pid, _}] -> Process.alive?(pid)
      _ -> false
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

  @doc """
  Check if a workspace's supervisor tree is registered. Returns true
  even if internal children (ServiceManager, etc.) have died — use
  `workspace_healthy?/1` for the stricter check.
  """
  def workspace_running?(workspace_id) do
    BoomLooper.WorkspaceGroup.whereis(workspace_id) != nil
  end

  @doc """
  Check whether the workspace's supervisor tree exists AND its
  essential child (ServiceManager) is alive. When a group is up but
  ServiceManager has died (transient + max_restarts hit, or an
  unexpected :normal exit), the LV's silent-reconnect path would
  think the workspace is fine and never retry compose — the stuck
  :starting bug. Callers that need to know "can this workspace
  actually do work" should use this, not `workspace_running?/1`.
  """
  def workspace_healthy?(workspace_id) do
    case BoomLooper.WorkspaceGroup.whereis(workspace_id) do
      nil -> false
      _pid -> healthy_group?(workspace_id)
    end
  end
end
