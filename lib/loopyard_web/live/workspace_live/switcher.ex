defmodule LoopyardWeb.Live.WorkspaceLive.Switcher do
  @moduledoc """
  Per-window view tracking for the workspace rail.

  `attach_view_tracker/1` records where the window is on every navigation, keyed
  by the LiveView connection (`transport_pid`) so two windows stay independent
  and the memory survives a workspace-switch remount. (The old
  `list_project_workspaces/2` was retired when the left rail became the god-mode
  global tree — see `Loopyard.WorkspaceTree` / #55.)
  """
  import Phoenix.LiveView, only: [connected?: 1, attach_hook: 4]

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
        path = view_path(uri)
        base = socket.assigns[:base_path]

        # Record only MEANINGFUL sub-views (agent / console / service / volume),
        # never the bare workspace base URL. The base is the transient `:index`
        # landing that immediately resumes/redirects — recording it would CLOBBER
        # this window's real last view, so the next return to the workspace would
        # fall back to "first agent" instead of where you actually were.
        if c && ws_id && is_binary(path) && path != base do
          Loopyard.WindowViews.touch(c, ws_id, path)
        end

        {:cont, socket}
      end)
    else
      socket
    end
  end

  defp view_path(uri), do: URI.parse(uri).path
end
