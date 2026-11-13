defmodule Loopyard.Workspace.AutostartTest do
  # async: false — writes rows into the shared :workspace_registry and
  # :chat_agents tables (unique ids, removed on exit).
  use ExUnit.Case, async: false

  alias Loopyard.AgentLog
  alias Loopyard.ChatAgent.Persistence
  alias Loopyard.Workspace.Autostart

  setup do
    ws_id = "autostart-#{System.unique_integer([:positive])}"
    agent_id = "agent-#{ws_id}"
    log_path = Persistence.log_path(ws_id)
    File.mkdir_p!(Path.dirname(log_path))

    AgentLog.append({:agent, agent_id, %{name: "Coder", status: :idle, workspace_id: ws_id}},
      log_path: log_path,
      version: 1
    )

    on_exit(fn ->
      :ets.delete(:workspace_registry, ws_id)
      :ets.delete(:chat_agents, agent_id)
      File.rm_rf!(Loopyard.Workspace.compose_dir(ws_id))
    end)

    %{ws_id: ws_id, agent_id: agent_id}
  end

  # The reboot case: the daemon was down at boot, so this workspace was
  # registered only after the boot-time agent replay had already run.
  test "replays the agents of a workspace registered after boot, once", %{
    ws_id: ws_id,
    agent_id: agent_id
  } do
    :ets.insert(:workspace_registry, {ws_id, %{id: ws_id}})
    assert :ets.lookup(:chat_agents, agent_id) == []

    assert Autostart.prime_unloaded() >= 1

    assert [{^agent_id, %{name: "Coder", workspace_id: ^ws_id}}] =
             :ets.lookup(:chat_agents, agent_id)

    # Already loaded: a second pass must not re-replay over live state.
    :ets.update_element(
      :chat_agents,
      agent_id,
      {2, %{id: agent_id, name: "Coder", workspace_id: ws_id, status: :thinking}}
    )

    Autostart.prime_unloaded()
    assert [{_, %{status: :thinking}}] = :ets.lookup(:chat_agents, agent_id)
  end

  test "skips a workspace still in setup", %{ws_id: ws_id, agent_id: agent_id} do
    :ets.insert(:workspace_registry, {ws_id, %{id: ws_id, setup: %{phase: :running}}})
    Autostart.prime_unloaded()
    assert :ets.lookup(:chat_agents, agent_id) == []
  end
end
