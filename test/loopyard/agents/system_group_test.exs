defmodule Loopyard.Agents.SystemGroupTest do
  @moduledoc """
  System agents get the same supervision shape workspace agents have: a
  group per identity with an agent supervisor, a RestartController keyed
  `{:system, identity}`, and a Checkpointer on the identity's agents log.
  """
  use ExUnit.Case, async: false

  alias Loopyard.Agents.{SystemGroup, SystemSupervisor}
  alias Loopyard.ChatAgent.{Persistence, RestartController}

  setup do
    identity = "sg-test-#{System.unique_integer([:positive])}"
    on_exit(fn -> if pid = SystemGroup.whereis(identity), do: Supervisor.stop(pid, :normal) end)
    {:ok, identity: identity}
  end

  test "ensure_group/1 boots the group once and registers its three children", %{identity: id} do
    assert {:ok, pid} = SystemSupervisor.ensure_group(id)
    assert {:ok, ^pid} = SystemSupervisor.ensure_group(id), "idempotent"
    assert SystemGroup.whereis(id) == pid

    key = {:system, id}
    assert [{_, _}] = Registry.lookup(Loopyard.WorkspaceAgentRegistry, key)
    assert [{_, _}] = Registry.lookup(Loopyard.ChatAgent.RestartControllerRegistry, key)
    assert [{_, _}] = Registry.lookup(Loopyard.AgentLog.CheckpointerRegistry, key)
  end

  test "start_agent/2 refuses when the group isn't running", %{identity: id} do
    assert {:error, :group_not_running} = SystemGroup.start_agent(id, id: "nope")
  end

  test "a system agent's log is the identity's agents.log, by scope", %{identity: id} do
    assert Persistence.log_path_for(%{scope: :system, workstation_identity: id}) ==
             Path.join(Loopyard.Workstation.dir(id), "agents.log")

    # An operator row from before scopes existed (no workspace, a container).
    assert Persistence.log_path_for(%{workstation_identity: id, container: "loopyard-ws-x"}) ==
             Persistence.system_log_path(id)

    assert Persistence.log_path_for(%{workspace_id: "ws1"}) == Persistence.log_path("ws1")
    assert Persistence.log_path_for(%{}) == nil
  end

  test "the scope key: a workspace id, or {:system, identity}", %{identity: id} do
    assert Loopyard.Agents.scope_key(%{workspace_id: "ws1"}) == "ws1"
    assert Loopyard.Agents.scope_key(%{scope: :system, workstation_identity: id}) == {:system, id}
    assert Loopyard.Agents.scope(%{workspace_id: "ws1"}) == :workspace
    assert Loopyard.Agents.scope(%{container: "c", workstation_identity: id}) == :system
  end

  test "the controller's agent supervisor name is keyed by scope", %{identity: id} do
    assert RestartController.agent_sup_name("ws1") ==
             {:via, Registry, {Loopyard.WorkspaceAgentRegistry, "ws1"}}

    assert RestartController.agent_sup_name({:system, id}) ==
             {:via, Registry, {Loopyard.WorkspaceAgentRegistry, {:system, id}}}
  end
end
