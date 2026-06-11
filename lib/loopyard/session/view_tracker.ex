defmodule Loopyard.Session.ViewTracker do
  @moduledoc """
  Per-browser-session "where was I" memory: the last view (path) a session was
  on in each workspace, so the workspace switcher can resume there instead of
  resetting to a default.

  This is server-driven UI state (no client storage), held in a SINGLE ETS table
  owned by `Loopyard.StateKeeper` — deliberately one shared table rather than a
  GenServer per session. The data is a key→value lookup with no behavior, so a
  process per browser would be over-modeling and would fragment state across
  thousands of actors; one table keeps it in the one place this app already
  centralizes ETS.

  Keyed by `{session_id, workspace_id} => {path, last_touch_ms}`. Reads expire
  stale rows lazily (TTL). Node-local: single-node today; a multi-node deploy
  would need session affinity or a distributed store (the standard caveat for
  any node-local cache here).
  """
  @table :session_views
  @ttl_ms 12 * 60 * 60 * 1000

  @doc "Record the path a session is currently viewing in a workspace."
  @spec touch(String.t(), String.t(), String.t()) :: :ok
  def touch(session_id, workspace_id, path)
      when is_binary(session_id) and is_binary(workspace_id) and is_binary(path) do
    :ets.insert(@table, {{session_id, workspace_id}, path, now_ms()})
    :ok
  end

  def touch(_, _, _), do: :ok

  @doc """
  The last path a session viewed in a workspace, or `nil`. Rows older than the
  TTL are expired (and deleted) on read.
  """
  @spec resume_path(String.t() | nil, String.t()) :: String.t() | nil
  def resume_path(session_id, workspace_id)
      when is_binary(session_id) and is_binary(workspace_id) do
    case :ets.lookup(@table, {session_id, workspace_id}) do
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

  defp now_ms, do: System.system_time(:millisecond)
end
