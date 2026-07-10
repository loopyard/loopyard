defmodule Loopyard.WorkspaceTree do
  @moduledoc """
  The global projects → workspaces → agents tree for the god-mode sidebar (#55).

  Pure assembly from the registries + `:chat_agents` ETS — no side effects, safe
  to call from any LiveView mount/refresh. Live updates ride the activity stream
  (`Loopyard.Events.Activity`), so callers subscribe once and rebuild (or patch)
  on each event. Kept separate from any view so it's reusable (the Foreman's
  read-only view wants the same tree) and trivially rip-out-able.
  """

  @doc """
  Every project, each with its workspaces, each with its agents (id, name,
  status, active tool). Sorted by project then workspace name.
  """
  def global do
    agents_by_ws =
      Loopyard.ChatAgent.list_agents()
      |> Enum.group_by(&Map.get(&1, :workspace_id))

    Loopyard.ProjectRegistry.list_projects()
    |> Enum.map(fn project ->
      workspaces =
        Loopyard.WorkspaceRegistry.list_workspaces(project.id)
        |> Enum.map(fn ws ->
          agents =
            agents_by_ws
            |> Map.get(ws.id, [])
            |> Enum.map(&agent_node/1)
            |> Enum.sort_by(& &1.name)

          %{id: ws.id, name: ws[:name] || ws.id, agents: agents}
        end)
        |> Enum.sort_by(& &1.name)

      %{id: project.id, name: project.name, workspaces: workspaces}
    end)
    |> Enum.sort_by(& &1.name)
  rescue
    _ -> []
  end

  defp agent_node(a) do
    # NOTE: pass through `:status` + `:quarantined` (what the shared
    # `Sidebar.agent_display_status/1` normalizer reads), but deliberately
    # DO NOT set `:alive?` — a nil value there reads as "not alive" (sleeping);
    # leaving the key absent lets the normalizer fall back to the authoritative
    # Registry liveness lookup. Keeps the god-mode rail's dot identical to the
    # right pane's for the same agent.
    %{
      id: a.id,
      name: Map.get(a, :name) || "Agent",
      status: Map.get(a, :status),
      quarantined: Map.get(a, :quarantined),
      active_tool: Map.get(a, :active_tool)
    }
  end
end
