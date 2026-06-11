defmodule LoopyardWeb.Live.WorkspaceLive.Switcher do
  @moduledoc """
  Data + per-window view tracking for the left workspace-switcher rail.

  `list_project_workspaces/2` builds the sibling-workspace list (each enriched
  with this window's resume path + its latest agent). `attach_view_tracker/1`
  records where the window is on every navigation, keyed by the LiveView
  connection (`transport_pid`) so two windows stay independent and the memory
  survives a workspace-switch remount. Extracted from `WorkspaceLive` to keep
  that file under its line cap.
  """
  import Phoenix.LiveView, only: [connected?: 1, attach_hook: 4]

  @doc """
  Sibling workspaces of the project, for the switcher rail (cheap — ETS only).
  Each gets `:resume_path` (this window's last view there) + `:latest_agent_id`
  (the fallback landing target). `[]` when there's no project.
  """
  def list_project_workspaces(nil, _conn), do: []

  def list_project_workspaces(project, conn) do
    # list_agents/0 is newest-first, so the first agent per workspace is latest.
    agents_by_ws = Enum.group_by(Loopyard.ChatAgent.list_agents(), & &1[:workspace_id])

    Loopyard.ProjectRegistry.list_workspaces(project.id)
    |> Enum.map(fn ws ->
      latest = agents_by_ws |> Map.get(ws.id, []) |> List.first()

      ws
      |> Map.put(:latest_agent_id, latest && latest.id)
      |> Map.put(:resume_path, Loopyard.WindowViews.resume_path(conn, ws.id))
    end)
  end

  @doc """
  Record where this window is, per workspace, so the switcher resumes there. A
  handle_params hook fires on every navigation (initial + each patch), keyed by
  `socket.transport_pid` (the window's connection — stable across the
  workspace-switch remount, unique per window). Also registers connection-DOWN
  cleanup via `Loopyard.Resources` (owner = the connection, so a switch is not a
  teardown). Re-tracking on each mount is idempotent.
  """
  def attach_view_tracker(socket) do
    if connected?(socket) do
      conn = socket.transport_pid

      Loopyard.Resources.track(conn, :window_views, conn, fn ->
        Loopyard.WindowViews.clear(conn)
      end)

      attach_hook(socket, :track_view, :handle_params, fn _params, uri, socket ->
        c = socket.transport_pid
        ws_id = socket.assigns.workspace.id
        if c && ws_id, do: Loopyard.WindowViews.touch(c, ws_id, view_path(uri))
        {:cont, socket}
      end)
    else
      socket
    end
  end

  defp view_path(uri) do
    case URI.parse(uri) do
      %URI{path: path} -> path
      _ -> nil
    end
  end
end
