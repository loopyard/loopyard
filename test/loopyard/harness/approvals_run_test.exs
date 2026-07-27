defmodule Loopyard.Harness.ApprovalsRunTest do
  @moduledoc """
  Per-verb EFFECTS of `Approvals.run/3` — the queued model's execute step. The
  Docker-touching verbs (:fork / :integrate / :delete_workspace) shell out even
  on nonexistent targets, so they are deliberately NOT driven here; this covers
  the pure-registry verbs (:rename_project, :rename_workspace) and the
  malformed-action contract.
  """
  use ExUnit.Case, async: false

  alias Loopyard.Harness.Approvals

  setup do
    Loopyard.StateKeeper.ensure_tables!()
    :ok
  end

  describe ":rename_project" do
    test "renames a registered project" do
      n = System.unique_integer([:positive])
      project_id = "run-proj-#{n}"

      Loopyard.ProjectRegistry.register(%{
        id: project_id,
        name: "run-rename-before-#{n}",
        path: "/tmp/fake-#{project_id}"
      })

      on_exit(fn -> :ets.delete(:project_registry, project_id) end)

      assert :ok =
               Approvals.run("run-agent", nil, %{
                 verb: :rename_project,
                 project_id: project_id,
                 name: "run-rename-after-#{n}"
               })

      assert %{name: name} = Loopyard.ProjectRegistry.get_project(project_id)
      assert name == "run-rename-after-#{n}"
    end

    test "unknown project id returns :ok cleanly (no raise)" do
      assert :ok =
               Approvals.run("run-agent", nil, %{
                 verb: :rename_project,
                 project_id: "run-nope-#{System.unique_integer([:positive])}",
                 name: "whatever"
               })
    end

    test "unknown project id resolves the card to :failed" do
      agent_id = "run-card-agent-#{System.unique_integer([:positive])}"
      msg_id = "run-card-msg-#{System.unique_integer([:positive])}"

      # Seed the agent summary + pending card directly in ETS (no GenServer),
      # so resolve/3 takes the direct-ETS update path.
      :ets.insert(
        :chat_agents,
        {agent_id,
         %{
           id: agent_id,
           messages: [%{id: msg_id, role: :approval, status: :pending}]
         }}
      )

      on_exit(fn -> :ets.delete(:chat_agents, agent_id) end)

      assert :ok =
               Approvals.run(agent_id, msg_id, %{
                 verb: :rename_project,
                 project_id: "run-nope-#{System.unique_integer([:positive])}",
                 name: "whatever"
               })

      assert [{^agent_id, summary}] = :ets.lookup(:chat_agents, agent_id)
      assert [%{id: ^msg_id, status: :failed, error: error}] = summary.messages
      assert error =~ "not_found"
    end
  end

  describe ":rename_workspace" do
    test "merges the new name into the workspace's setup" do
      n = System.unique_integer([:positive])
      ws_id = "run-ws-#{n}"

      Loopyard.WorkspaceRegistry.insert(ws_id, %{
        id: ws_id,
        project_id: "run-ws-proj-#{n}",
        name: "before-#{n}",
        branch: "before-#{n}",
        path: "/tmp/fake-#{ws_id}",
        is_main: false,
        status: :stopped
      })

      on_exit(fn -> Loopyard.WorkspaceRegistry.delete(ws_id) end)

      assert :ok =
               Approvals.run("run-agent", nil, %{
                 verb: :rename_workspace,
                 workspace_id: ws_id,
                 name: "after-#{n}"
               })

      # update_setup merges into the :setup field — that's where the rename lands.
      assert %{setup: %{name: name}} = Loopyard.WorkspaceRegistry.get_workspace(ws_id)
      assert name == "after-#{n}"
    end

    test "unknown workspace id returns :ok cleanly (no raise)" do
      assert :ok =
               Approvals.run("run-agent", nil, %{
                 verb: :rename_workspace,
                 workspace_id: "run-nope-#{System.unique_integer([:positive])}",
                 name: "whatever"
               })
    end
  end

  describe "malformed actions" do
    test "an unknown verb falls to the catch-all → :ok" do
      assert :ok = Approvals.run("run-agent", nil, %{verb: :bogus_verb})
    end

    test "an action without a :verb key falls to the catch-all → :ok" do
      assert :ok = Approvals.run("run-agent", nil, %{whatever: true})
    end

    test "a matched verb missing its required keys raises KeyError (documents the current contract)" do
      # run/3 clauses access action.workspace_id etc. directly — a card that
      # matched a verb but lost its payload is a programmer error, not a
      # user-visible path. If this starts returning cleanly instead, update
      # this test to the new contract. (Built at runtime so the type checker
      # doesn't flag the deliberately-incomplete action literal.)
      # :rename_project without :project_id/:name — a matched clause with a
      # lost payload.
      action = Map.new([{:verb, :rename_project}])

      assert_raise KeyError, fn ->
        Approvals.run("run-agent", nil, action)
      end
    end
  end
end
