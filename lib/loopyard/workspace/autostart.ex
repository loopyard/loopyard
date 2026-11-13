defmodule Loopyard.Workspace.Autostart do
  @moduledoc """
  Bring back the last working state: start the workspaces that were in use
  ("in use" = it has restored agents), so a server restart does not leave you
  on crashed agents in powered-down workspaces (#52).

  Runs twice in a server's life, and both matter for an always-on service:

    * at boot (`Loopyard.Application`), and
    * on every Docker daemon down→up transition (`Loopyard.DockerDaemon`).

  The second is what makes a REBOOT work: the server usually boots before the
  container runtime, so the boot pass sees no containers and starts nothing,
  and the canonical projects are only registered once the daemon answers
  (`Onboarding.restore/0`) — after the boot-time agent replay already ran. The
  recovery pass first replays the agent log of every registered workspace not
  yet in ETS (`prime_unloaded/0`), then starts what was in use. Both steps are
  idempotent: a loaded workspace is never re-replayed (that would overwrite a
  live agent's status with the log's), and a healthy group is left alone.

  Only a workspace whose work container ALREADY EXISTS is started — never
  built or created fresh here. Each start runs in its own supervised Task so
  one slow or failing start neither blocks the caller nor the others.
  """
  require Logger

  @doc "Replay unloaded workspaces' agent logs, then start the ones in use."
  @spec run() :: :ok
  def run do
    prime_unloaded()
    autostart_used_workspaces()
    :ok
  end

  @doc """
  Replay into ETS the agent log of every registered, set-up workspace whose
  agents are not loaded yet. Returns how many workspaces were replayed.
  """
  @spec prime_unloaded() :: non_neg_integer()
  def prime_unloaded do
    :workspace_registry
    |> :ets.tab2list()
    |> Enum.map(fn {_id, ws} -> ws end)
    |> Enum.filter(&ready_workspace?/1)
    |> Enum.reject(&Loopyard.ChatAgent.workspace_loaded?(&1[:id]))
    |> Enum.count(&replay/1)
  end

  defp replay(ws) do
    log_path = Loopyard.ChatAgent.Persistence.log_path(ws[:id])

    with true <- is_binary(log_path) and File.exists?(log_path),
         {:ok, agents} when map_size(agents) > 0 <-
           Loopyard.AgentLog.replay(log_path: log_path, version: 1, ets_table: :chat_agents) do
      true
    else
      _ -> false
    end
  rescue
    e ->
      Logger.warning("[Loopyard] agent replay for #{ws[:id]} failed: #{Exception.message(e)}")
      false
  end

  defp autostart_used_workspaces do
    if Application.get_env(:loopyard, :autostart_workspaces_on_boot, true) do
      used_workspace_ids()
      |> Enum.each(fn ws_id ->
        ws = Loopyard.WorkspaceRegistry.get_workspace(ws_id)

        cond do
          is_nil(ws) or not ready_workspace?(ws) ->
            :ok

          # Container ALREADY RUNNING: the workspace group (ServiceManager /
          # AgentSupervisor / agent resume) must still start — before this,
          # a running workspace stayed headless until someone happened to
          # visit its page, and agents couldn't restart ("noproc" on the
          # workspace's AgentSupervisor). Group only — no container ops.
          work_container_running?(ws_id) ->
            Task.Supervisor.start_child(Loopyard.TaskSupervisor, fn ->
              autostart_group(ws_id, ws[:path])
            end)

          # Container exists but stopped: bring the whole workspace back
          # (group + container). Never build/create fresh on boot.
          work_container_stopped?(ws_id) ->
            Task.Supervisor.start_child(Loopyard.TaskSupervisor, fn ->
              autostart_one(ws_id, ws[:path])
            end)

          true ->
            :ok
        end
      end)
    end

    :ok
  end

  # Workspace ids that have at least one restored agent (were actually used).
  defp used_workspace_ids do
    :ets.tab2list(:chat_agents)
    |> Enum.map(fn {_id, summary} -> Map.get(summary, :workspace_id) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # Same guard as restore_all_agents: skip workspaces mid-setup. Legacy
  # workspaces (no :setup key) predate the saga and are safe.
  defp ready_workspace?(ws) do
    phase = get_in(ws, [:setup, :phase])
    phase == nil or phase == :ready
  end

  # The work container exists (workspace was set up) but isn't running.
  defp work_container_stopped?(ws_id) do
    name = Loopyard.Workspace.WorkContainer.container_name(ws_id)
    Loopyard.Docker.container_exists?(name) and not Loopyard.Docker.container_running?(name)
  end

  defp work_container_running?(ws_id) do
    Loopyard.Docker.container_running?(Loopyard.Workspace.WorkContainer.container_name(ws_id))
  end

  defp autostart_one(ws_id, path) do
    if path do
      Loopyard.WorkspaceSupervisor.start_workspace(ws_id, path)
      Loopyard.Workspace.WorkContainer.ensure_up(ws_id)
      Logger.info("[Loopyard] Auto-started workspace #{ws_id} on boot")
    end
  rescue
    e ->
      Logger.warning(
        "[Loopyard] Auto-start of workspace #{ws_id} failed: #{Exception.message(e)}"
      )
  end

  # Container already running — start ONLY the supervision group; its
  # ServiceManager reconnects to the live containers and resumes agents.
  defp autostart_group(ws_id, path) do
    if path do
      Loopyard.WorkspaceSupervisor.start_workspace(ws_id, path)
      Logger.info("[Loopyard] Attached workspace group #{ws_id} to running container on boot")
    end
  rescue
    e ->
      Logger.warning(
        "[Loopyard] Group attach of workspace #{ws_id} failed: #{Exception.message(e)}"
      )
  end
end
