defmodule Loopyard.Agents.SystemGroup do
  @moduledoc """
  The supervision group for one workstation identity's SYSTEM agents — the
  same shape a workspace's agents get from `Loopyard.WorkspaceGroup`, minus
  the workspace-only children (services, container monitor, log buffer):

    * a `DynamicSupervisor` for the agents, registered under
      `{:system, identity}` in `Loopyard.WorkspaceAgentRegistry` (the key
      space is any term; `RestartController.agent_sup_name/1` resolves it);
    * a `Loopyard.ChatAgent.RestartController` keyed `{:system, identity}` —
      crash history, quarantine, boot-failure accounting;
    * an `AgentLog.Checkpointer` on the identity's `agents.log`, so the log
      has one writer and gets compacted like a workspace's.

  The operator used to be a bare child of a global DynamicSupervisor with
  none of this. With N system agents that was visible; with one it was merely
  wrong.
  """
  use Supervisor

  alias Loopyard.ChatAgent.RestartController

  @registry Loopyard.Agents.SystemGroupRegistry

  def start_link(opts) do
    identity = Keyword.fetch!(opts, :identity)
    Supervisor.start_link(__MODULE__, opts, name: via(identity))
  end

  @impl true
  def init(opts) do
    identity = Keyword.fetch!(opts, :identity)
    key = key(identity)

    children = [
      {DynamicSupervisor, name: RestartController.agent_sup_name(key), strategy: :one_for_one},
      {RestartController, scope: key},
      {Loopyard.AgentLog.Checkpointer,
       [
         workspace_id: key,
         log_path: Loopyard.ChatAgent.Persistence.system_log_path(identity),
         version: 1,
         name: Loopyard.AgentLog.Checkpointer.via(key)
       ]}
    ]

    Supervisor.init(children, strategy: :one_for_all, max_restarts: 10, max_seconds: 60)
  end

  @doc "The scope key for an identity's system agents."
  def key(identity) when is_binary(identity), do: {:system, identity}

  @doc """
  Start a ChatAgent under this identity's group, through the
  RestartController so crash tracking + quarantine apply from the first spawn.
  """
  def start_agent(identity, agent_opts) when is_binary(identity) do
    case whereis(identity) do
      nil -> {:error, :group_not_running}
      _pid -> RestartController.start_agent(key(identity), agent_opts)
    end
  end

  @doc "The group's pid, or nil."
  def whereis(identity) do
    case Registry.lookup(@registry, identity) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp via(identity), do: {:via, Registry, {@registry, identity}}
end
