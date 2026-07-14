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
  Every project, each with its workspaces, each with its agents. The ONE tree
  both birdseye surfaces (sidebar + home page) render, so they can't drift.
  Sorted by project then workspace name.

  Pass `host` to include openable port URLs on each workspace (built from the
  host the browser is on); omit it (the rail's compact use) and ports are `[]`.
  """
  def global(host \\ nil) do
    # ETS-only read (no per-agent GenServer poll). Status in ETS is authoritative
    # — every transition writes ETS before broadcasting — so this stays fresh
    # without fleet-wide `get_state` round-trips on each rebuild.
    agents_by_ws =
      Loopyard.ChatAgent.list_agent_summaries()
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

          %{id: ws.id, name: ws[:name] || ws.id, agents: agents, ports: ws_ports(ws.id, host)}
        end)
        |> Enum.sort_by(& &1.name)

      %{
        id: project.id,
        name: project.name,
        # Raw location fields; the view formats them (Format.project_location).
        path: project[:path],
        git_url: project[:git_url],
        workspaces: workspaces
      }
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
      workspace_id: Map.get(a, :workspace_id),
      name: Map.get(a, :name) || "Agent",
      status: Map.get(a, :status),
      quarantined: Map.get(a, :quarantined),
      active_tool: Map.get(a, :active_tool),
      model: Map.get(a, :model),
      cost: Map.get(a, :total_cost_usd)
    }
  end

  # Exposed (network-open) ports for a workspace, as clickable targets. Only
  # exposed ports are reachable from the browser. `nil` host → no URLs (the rail
  # doesn't need them).
  defp ws_ports(_workspace_id, nil), do: []

  defp ws_ports(workspace_id, host) do
    Loopyard.PortRegistry.list_for_workspace(workspace_id)
    |> Enum.filter(& &1.exposed)
    |> Enum.map(fn p -> %{port: p.host_port, url: "http://#{host}:#{p.host_port}"} end)
    |> Enum.sort_by(& &1.port)
  rescue
    _ -> []
  end
end
