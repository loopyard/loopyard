defmodule Loopyard.WindowViews do
  @moduledoc """
  Per-window "where was I" memory: the last view (path) each browser WINDOW was
  on in each workspace, so the workspace switcher resumes there.

  Keyed by the LiveView connection — `socket.transport_pid` — which is:

    * unique per window/tab (each has its own WebSocket), and
    * stable across live navigation (the same socket survives a workspace
      switch even though the per-workspace LiveView process remounts).

  That per-window scope is the whole point of the scenario this solves: two
  windows of the same browser navigate independently and must NOT clobber each
  other's "last view" — which a per-browser key (cookie / localStorage) would.
  The connection is the LiveView's window, so this is per-window LiveView state;
  we hold it in one StateKeeper-owned ETS table rather than assigns only because
  the state has to outlive the switch-remount (assigns don't), and a sticky
  child LiveView to keep it in assigns buys nothing behaviorally.

  Lazy TTL on read; rows for closed windows age out. Node-local — a single
  window lives on one node, so this never needs to cross the cluster.
  """
  @table :window_views
  @ttl_ms 12 * 60 * 60 * 1000

  @doc "Record the path a window is currently viewing in a workspace."
  @spec touch(pid() | nil, String.t(), String.t() | nil) :: :ok
  def touch(conn, workspace_id, path)
      when is_pid(conn) and is_binary(workspace_id) and is_binary(path) do
    :ets.insert(@table, {{conn, workspace_id}, path, now_ms()})
    :ok
  end

  def touch(_, _, _), do: :ok

  @doc "The last path this window viewed in the workspace, or nil. Expires stale rows on read."
  @spec resume_path(pid() | nil, String.t()) :: String.t() | nil
  def resume_path(conn, workspace_id) when is_pid(conn) and is_binary(workspace_id) do
    case :ets.lookup(@table, {conn, workspace_id}) do
      [{key, path, ts}] ->
        if now_ms() - ts <= @ttl_ms do
          path
        else
          :ets.delete(@table, key)
          nil
        end

      [] ->
        nil
    end
  end

  def resume_path(_, _), do: nil

  @doc """
  Delete every row for a window's connection. Called when that connection goes
  DOWN (window/tab closed, socket dropped) via `Loopyard.Resources` ownership —
  so rows don't linger until the TTL. A no-op for a non-pid.
  """
  @spec clear(pid() | term()) :: :ok
  def clear(conn) when is_pid(conn) do
    :ets.match_delete(@table, {{conn, :_}, :_, :_})
    :ok
  end

  def clear(_), do: :ok

  defp now_ms, do: System.system_time(:millisecond)
end
