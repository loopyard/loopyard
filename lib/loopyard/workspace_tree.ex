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
          summaries = Map.get(agents_by_ws, ws.id, [])

          agents =
            summaries
            |> Enum.map(&agent_node/1)
            |> Enum.sort_by(& &1.name)

          %{
            id: ws.id,
            name: ws[:name] || ws.id,
            agents: agents,
            ports: ws_ports(ws.id, host),
            # WORKSPACE-level derived signals for the overview surfaces (#55).
            # Computed from the RAW summaries (which still carry :messages)
            # before agent_node strips them down. All ETS-cheap — the
            # /workspaces mount-budget test holds.
            needs_you: needs_you(summaries),
            broken: broken(summaries),
            last_activity_at: last_activity(summaries),
            # Cached ±N (event-driven, Loopyard.ChangeCounts) — nil = unknown
            # (no running work container / not computed yet), never a fake 0.
            changes: Loopyard.ChangeCounts.get(ws.id)
          }
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
      cost: Map.get(a, :total_cost_usd),
      last_activity_at: Map.get(a, :last_activity_at)
    }
  end

  # --- Workspace-level signal derivation (the overview's four human questions) ---

  # Is any agent here WAITING ON THE HUMAN? Returns what it's waiting for
  # (:question | :approval | :secret) or nil. Questions/Secrets are tiny-ETS
  # scans with waiter-liveness reaping; queued approvals live only in the
  # message stream, so those are found via pending_in_messages?/1 (the blocking
  # legacy path via pending_for_agent?). First match wins, question loudest.
  defp needs_you(summaries) do
    Enum.find_value(summaries, fn a ->
      id = a.id

      cond do
        Loopyard.Harness.Questions.pending_for_agent?(id) -> :question
        Loopyard.Harness.Approvals.pending_for_agent?(id) -> :approval
        Loopyard.Harness.Approvals.pending_in_messages?(Map.get(a, :messages) || []) -> :approval
        Loopyard.Harness.SecretRequests.pending_for_agent?(id) -> :secret
        true -> nil
      end
    end)
  rescue
    _ -> nil
  end

  # Genuinely BROKEN — needs human intervention, never wakes on its own:
  # auth expired (re-login) or quarantined (crash-looping, held by the
  # RestartController). A merely :crashed/:stopped agent is NOT broken — it's
  # asleep and wakes on the next message (#64) — so it stays out of here.
  # Service-crashed (nonzero exit) joins in a follow-up once Docker.Observer
  # retains exit codes; a cleanly-stopped cluster must never read as broken.
  defp broken(summaries) do
    Enum.find_value(summaries, fn a ->
      cond do
        Map.get(a, :status) == :auth_expired -> :auth_expired
        Map.get(a, :quarantined) -> :quarantined
        true -> nil
      end
    end)
  end

  # Most recent agent activity in the workspace (or nil) — the "active 5m ago"
  # fact on the roomier overview sizes.
  defp last_activity(summaries) do
    summaries
    |> Enum.map(&Map.get(&1, :last_activity_at))
    |> Enum.filter(&match?(%DateTime{}, &1))
    |> Enum.max(DateTime, fn -> nil end)
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
