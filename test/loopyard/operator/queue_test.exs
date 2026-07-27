defmodule Loopyard.Operator.QueueTest do
  @moduledoc """
  The operator's working list — a pure function over the WorkspaceTree shape
  plus the `:operator_jobs` read-position ETS. Fabricated tree input drives the
  state mapping (working → :chugging, idle → :done, needs_you/broken →
  :needs_you), the 48h recency window, ordering, and the dispatched-job delta.
  """
  use ExUnit.Case, async: false

  alias Loopyard.Operator.Queue

  @now ~U[2026-07-26 12:00:00Z]

  setup do
    Loopyard.StateKeeper.ensure_tables!()
    :ok
  end

  test "a working agent maps to :chugging" do
    ws = ws(agents: [agent(status: :thinking)], last_activity_at: minutes_ago(5))

    assert [item] = Queue.items(tree([ws]), @now)
    assert item.id == ws.id
    assert item.state == :chugging
    assert item.needs == "working…"
    assert item.agent_id == hd(ws.agents).id
  end

  test "an idle agent with recent activity maps to :done" do
    ws = ws(agents: [agent(status: :idle)], last_activity_at: minutes_ago(5))

    assert [item] = Queue.items(tree([ws]), @now)
    assert item.state == :done
    assert item.needs == "done"
  end

  test "a workspace waiting on the human maps to :needs_you with the reason" do
    ws =
      ws(
        agents: [agent(status: :idle)],
        needs_you: :question,
        last_activity_at: minutes_ago(5)
      )

    assert [item] = Queue.items(tree([ws]), @now)
    assert item.state == :needs_you
    assert item.needs == "asked a question"
  end

  test "a broken workspace also maps to :needs_you" do
    ws =
      ws(
        agents: [agent(status: :idle)],
        broken: :service_crashed,
        last_activity_at: minutes_ago(5)
      )

    assert [item] = Queue.items(tree([ws]), @now)
    assert item.state == :needs_you
    assert item.needs == "service crashed"
  end

  test "carries project + workspace naming for the card" do
    ws = ws(agents: [agent()], last_activity_at: minutes_ago(1))
    [project] = tree([ws])

    assert [item] = Queue.items([project], @now)
    assert item.project_id == project.id
    assert item.project_name == project.name
    assert item.workspace_name == ws.name
    assert item.last_activity_at == ws.last_activity_at
  end

  describe "recency window" do
    test "activity older than 48h is dropped" do
      stale = ws(agents: [agent()], last_activity_at: hours_ago(49))
      fresh = ws(agents: [agent()], last_activity_at: hours_ago(47))

      assert [item] = Queue.items(tree([stale, fresh]), @now)
      assert item.id == fresh.id
    end

    test "a workspace with no activity timestamp is dropped" do
      ws = ws(agents: [agent()], last_activity_at: nil)
      assert Queue.items(tree([ws]), @now) == []
    end
  end

  test "a workspace with no agents and no dispatched job is dropped" do
    ws = ws(agents: [], last_activity_at: minutes_ago(5))
    assert Queue.items(tree([ws]), @now) == []
  end

  test "items are sorted most-recent first" do
    older = ws(agents: [agent()], last_activity_at: hours_ago(3))
    newer = ws(agents: [agent()], last_activity_at: minutes_ago(10))

    assert [first, second] = Queue.items(tree([older, newer]), @now)
    assert first.id == newer.id
    assert second.id == older.id
  end

  test "a dispatched job anchors the agent and the unread delta" do
    job_agent_id = "q-job-agent-#{System.unique_integer([:positive])}"

    # The dispatched agent's transcript: 3 messages, read-position anchored at 1
    # → delta 2 (new messages since the operator last looked).
    :ets.insert(
      :chat_agents,
      {job_agent_id, %{id: job_agent_id, messages: [%{id: "m1"}, %{id: "m2"}, %{id: "m3"}]}}
    )

    ws = ws(agents: [agent()], last_activity_at: minutes_ago(5))
    :ets.insert(:operator_jobs, {ws.id, %{agent_id: job_agent_id, read_count: 1}})

    on_exit(fn ->
      :ets.delete(:chat_agents, job_agent_id)
      :ets.delete(:operator_jobs, ws.id)
    end)

    assert [item] = Queue.items(tree([ws]), @now)
    # The job's agent wins over the workspace's first live agent…
    assert item.agent_id == job_agent_id
    # …and the delta is messages-since-read.
    assert item.delta == 2
  end

  test "without a job the delta is 0 and the workspace's first agent is used" do
    ws = ws(agents: [agent(), agent()], last_activity_at: minutes_ago(5))

    assert [item] = Queue.items(tree([ws]), @now)
    assert item.agent_id == hd(ws.agents).id
    assert item.delta == 0
  end

  test "a non-list tree yields no items" do
    assert Queue.items(nil, @now) == []
  end

  # --- helpers: fabricated WorkspaceTree shapes ---

  defp ws(attrs) do
    n = System.unique_integer([:positive])

    Map.merge(
      %{
        id: "q-ws-#{n}",
        name: "q-ws-#{n}",
        agents: [],
        ports: [],
        needs_you: nil,
        broken: nil,
        changes: nil,
        last_activity_at: nil
      },
      Map.new(attrs)
    )
  end

  defp agent(attrs \\ []) do
    n = System.unique_integer([:positive])

    Map.merge(
      %{id: "q-agent-#{n}", name: "Agent #{n}", status: :idle, active_tool: nil},
      Map.new(attrs)
    )
  end

  defp tree(workspaces) do
    n = System.unique_integer([:positive])
    [%{id: "q-proj-#{n}", name: "Project #{n}", path: nil, git_url: nil, workspaces: workspaces}]
  end

  defp minutes_ago(m), do: DateTime.add(@now, -m * 60, :second)
  defp hours_ago(h), do: DateTime.add(@now, -h * 3600, :second)
end
