defmodule BoomLooperWeb.Live.WorkspaceLive.AgentLifecycleTest do
  @moduledoc """
  Regression coverage for the `list_workspace_agents/1` filter.

  The sidebar displays agents per workspace. Pre-fix the filter used
  `working_dir == workspace_path OR bind_mount == workspace_path`,
  which silently hid every agent whose working_dir legitimately
  differed from the workspace root:

    - Volume-based agents whose working_dir is the IN-CONTAINER path
      (`/workspace`)
    - Agents running from a subdirectory
    - Agents with a nil bind_mount + a path that doesn't match
      exactly

  All of these are valid and associated with the workspace by the
  `workspace_id` field. The new filter uses that.

  We want this class of bug to fail a test the next time it's
  reintroduced. The test sets up ETS rows with mismatched paths +
  the correct workspace_id, and asserts the agent appears.
  """

  use ExUnit.Case, async: false

  alias BoomLooperWeb.Live.WorkspaceLive.AgentLifecycle

  setup do
    # Make sure StateKeeper ETS tables exist for this test.
    BoomLooper.StateKeeper.ensure_tables!()

    workspace_path = "/Users/test/some/project-#{:rand.uniform(100_000)}"
    workspace_id = BoomLooper.Workspace.workspace_id(workspace_path)

    on_exit(fn ->
      :ets.tab2list(:chat_agents)
      |> Enum.filter(fn {_, s} -> s[:workspace_id] == workspace_id end)
      |> Enum.each(fn {id, _} -> :ets.delete(:chat_agents, id) end)
    end)

    %{workspace_path: workspace_path, workspace_id: workspace_id}
  end

  defp seed_agent(id, workspace_id, overrides) do
    base = %{
      id: id,
      name: "Test Agent #{id}",
      workspace_id: workspace_id,
      working_dir: "/unrelated/path",
      bind_mount: nil,
      status: :idle,
      started_at: DateTime.utc_now(),
      last_activity_at: DateTime.utc_now(),
      messages: []
    }

    :ets.insert(:chat_agents, {id, Map.merge(base, overrides)})
  end

  describe "list_workspace_agents/1 — filter by workspace_id, not path" do
    test "agent with /workspace container-path working_dir still shows up in sidebar",
         %{workspace_path: workspace_path, workspace_id: workspace_id} do
      id = "container-agent-#{:rand.uniform(100_000)}"
      # Volume-based agent — working_dir is IN-CONTAINER path, not
      # the host workspace path. Pre-fix this was filtered out.
      seed_agent(id, workspace_id, %{working_dir: "/workspace", bind_mount: nil})

      result = AgentLifecycle.list_workspace_agents(workspace_path)

      assert Enum.any?(result, &(&1.id == id)),
             "agent with container-scoped working_dir must show up in workspace sidebar"
    end

    test "agent with bind_mount matching path shows up (happy path)",
         %{workspace_path: workspace_path, workspace_id: workspace_id} do
      id = "bind-agent-#{:rand.uniform(100_000)}"
      seed_agent(id, workspace_id, %{bind_mount: workspace_path, working_dir: workspace_path})

      result = AgentLifecycle.list_workspace_agents(workspace_path)
      assert Enum.any?(result, &(&1.id == id))
    end

    test "agent with working_dir == a subdirectory still shows up",
         %{workspace_path: workspace_path, workspace_id: workspace_id} do
      id = "subdir-agent-#{:rand.uniform(100_000)}"

      seed_agent(id, workspace_id, %{
        working_dir: Path.join(workspace_path, "apps/web"),
        bind_mount: nil
      })

      result = AgentLifecycle.list_workspace_agents(workspace_path)
      assert Enum.any?(result, &(&1.id == id))
    end

    test "agent for a DIFFERENT workspace does NOT appear",
         %{workspace_path: workspace_path, workspace_id: _workspace_id} do
      other_workspace_id = "other-#{:rand.uniform(100_000)}"
      id = "other-agent-#{:rand.uniform(100_000)}"
      seed_agent(id, other_workspace_id, %{working_dir: workspace_path})

      # Even though working_dir matches, the workspace_id doesn't — it
      # belongs to a DIFFERENT workspace.
      result = AgentLifecycle.list_workspace_agents(workspace_path)
      refute Enum.any?(result, &(&1.id == id))

      # Clean up.
      :ets.delete(:chat_agents, id)
    end

    test "annotates :alive? based on Registry lookup",
         %{workspace_path: workspace_path, workspace_id: workspace_id} do
      id = "alive-agent-#{:rand.uniform(100_000)}"
      seed_agent(id, workspace_id, %{working_dir: "/somewhere"})

      [result] =
        AgentLifecycle.list_workspace_agents(workspace_path)
        |> Enum.filter(&(&1.id == id))

      # No GenServer registered → :alive? is false
      assert result.alive? == false
    end
  end
end
