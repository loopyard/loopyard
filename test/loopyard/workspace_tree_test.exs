defmodule Loopyard.WorkspaceTreeTest do
  @moduledoc """
  The projects → workspaces → agents overview tree — pure aggregation over the
  registries + `:chat_agents` ETS. Fabricated registry rows and agent summaries
  drive the derived workspace signals (`needs_you` / `broken` /
  `last_activity_at`); nothing here touches Docker or spawns agents.
  """
  use ExUnit.Case, async: false

  alias Loopyard.WorkspaceTree

  setup do
    Loopyard.StateKeeper.ensure_tables!()
    :ok
  end

  test "assembles project → workspace → agent nodes from the registries + ETS" do
    {project_id, ws_id} = seed_workspace()
    now = DateTime.utc_now()

    seed_agent("wt-agent-#{System.unique_integer([:positive])}", ws_id, %{
      name: "Zed",
      status: :thinking,
      active_tool: "exec",
      model: "claude-x",
      total_cost_usd: 1.25,
      last_activity_at: now
    })

    assert %{name: _} = project = find_project(project_id)
    assert %{} = ws = Enum.find(project.workspaces, &(&1.id == ws_id))

    assert [agent] = ws.agents
    assert agent.name == "Zed"
    assert agent.status == :thinking
    assert agent.active_tool == "exec"
    assert agent.model == "claude-x"
    assert agent.cost == 1.25
    assert agent.last_activity_at == now

    # No host passed → no port URLs; no ChangeCounts entry → nil, never a fake 0.
    assert ws.ports == []
    assert ws.changes == nil
    assert ws.needs_you == nil
    assert ws.broken == nil
  end

  test "agents are sorted by name and a workspace with no agents still appears" do
    {project_id, ws_id} = seed_workspace()
    {^project_id, empty_ws_id} = seed_workspace(project_id)

    seed_agent("wt-b-#{System.unique_integer([:positive])}", ws_id, %{name: "bravo"})
    seed_agent("wt-a-#{System.unique_integer([:positive])}", ws_id, %{name: "alpha"})

    project = find_project(project_id)
    ws = Enum.find(project.workspaces, &(&1.id == ws_id))
    assert Enum.map(ws.agents, & &1.name) == ["alpha", "bravo"]

    empty_ws = Enum.find(project.workspaces, &(&1.id == empty_ws_id))
    assert empty_ws.agents == []
  end

  describe "needs_you" do
    test "a pending approval card in the agent's messages flags :approval" do
      {project_id, ws_id} = seed_workspace()

      seed_agent("wt-appr-#{System.unique_integer([:positive])}", ws_id, %{
        messages: [%{id: "m1", role: :approval, status: :pending}]
      })

      assert find_ws(project_id, ws_id).needs_you == :approval
    end

    test "a resolved approval card does NOT flag" do
      {project_id, ws_id} = seed_workspace()

      seed_agent("wt-appr-done-#{System.unique_integer([:positive])}", ws_id, %{
        messages: [%{id: "m1", role: :approval, status: :approved}]
      })

      assert find_ws(project_id, ws_id).needs_you == nil
    end

    test "a pending question (broker entry) flags :question — loudest, beats an approval card" do
      {project_id, ws_id} = seed_workspace()
      agent_id = "wt-q-#{System.unique_integer([:positive])}"

      seed_agent(agent_id, ws_id, %{
        messages: [%{id: "m1", role: :approval, status: :pending}]
      })

      qid = "wt-qid-#{System.unique_integer([:positive])}"
      # A live waiter (this test process) makes the question genuinely pending.
      :ets.insert(:harness_questions, {qid, %{agent_id: agent_id, waiter: self(), msg_id: nil}})
      on_exit(fn -> :ets.delete(:harness_questions, qid) end)

      assert find_ws(project_id, ws_id).needs_you == :question
    end
  end

  describe "broken" do
    test "an auth-expired agent flags :auth_expired" do
      {project_id, ws_id} = seed_workspace()

      seed_agent("wt-auth-#{System.unique_integer([:positive])}", ws_id, %{
        status: :auth_expired
      })

      assert find_ws(project_id, ws_id).broken == :auth_expired
    end

    test "a quarantined agent flags :quarantined" do
      {project_id, ws_id} = seed_workspace()

      seed_agent("wt-quar-#{System.unique_integer([:positive])}", ws_id, %{
        status: :idle,
        quarantined: true
      })

      assert find_ws(project_id, ws_id).broken == :quarantined
    end

    test "a merely :crashed agent is asleep, NOT broken" do
      {project_id, ws_id} = seed_workspace()
      seed_agent("wt-crash-#{System.unique_integer([:positive])}", ws_id, %{status: :crashed})

      ws = find_ws(project_id, ws_id)
      assert ws.broken == nil
      assert ws.needs_you == nil
    end
  end

  test "last_activity_at is the most recent across the workspace's agents" do
    {project_id, ws_id} = seed_workspace()
    older = DateTime.add(DateTime.utc_now(), -3600, :second)
    newer = DateTime.utc_now()

    seed_agent("wt-old-#{System.unique_integer([:positive])}", ws_id, %{
      name: "old",
      last_activity_at: older
    })

    seed_agent("wt-new-#{System.unique_integer([:positive])}", ws_id, %{
      name: "new",
      last_activity_at: newer
    })

    assert find_ws(project_id, ws_id).last_activity_at == newer
  end

  # --- helpers ---

  # Fabricated project + workspace rows — pure ETS, no source adapter, no Docker.
  defp seed_workspace(project_id \\ nil) do
    n = System.unique_integer([:positive])

    project_id =
      project_id ||
        (fn ->
           id = "wt-proj-#{n}"
           Loopyard.ProjectRegistry.register(%{id: id, name: "wt-proj-#{n}", path: "/tmp/#{id}"})
           on_exit(fn -> :ets.delete(:project_registry, id) end)
           id
         end).()

    ws_id = "wt-ws-#{n}"

    Loopyard.WorkspaceRegistry.insert(ws_id, %{
      id: ws_id,
      project_id: project_id,
      name: "wt-ws-#{n}",
      branch: "wt-ws-#{n}",
      path: "/tmp/#{ws_id}",
      is_main: false,
      status: :stopped
    })

    on_exit(fn -> Loopyard.WorkspaceRegistry.delete(ws_id) end)
    {project_id, ws_id}
  end

  # Fabricated agent summary in :chat_agents — the shape WorkspaceTree reads.
  defp seed_agent(id, ws_id, attrs) do
    summary =
      Map.merge(
        %{id: id, workspace_id: ws_id, name: "Agent #{id}", status: :idle, messages: []},
        attrs
      )

    :ets.insert(:chat_agents, {id, summary})
    on_exit(fn -> :ets.delete(:chat_agents, id) end)
    id
  end

  defp find_project(project_id) do
    WorkspaceTree.global() |> Enum.find(&(&1.id == project_id))
  end

  defp find_ws(project_id, ws_id) do
    find_project(project_id).workspaces |> Enum.find(&(&1.id == ws_id))
  end
end
