defmodule Loopyard.Operator.Jobs do
  @moduledoc """
  The operator's WORKER QUEUE — one job per workspace you've dispatched to. It
  starts blank; `note_dispatch/2` adds a job (anchoring your read-position at the
  moment you dispatched). The "delta since you last looked" is the heart of it:
  `delta(ws_id) = current message count − read_count`. Diving in (or dispatching
  again) re-anchors `read_count` to now, so the delta resets. That single marker
  does double duty — it's both the unread count on the card AND the inbox-style
  retirement (a done job with a 0 delta has been read → it retires).

  ETS-only (`:operator_jobs` via StateKeeper); safe to call from anywhere.
  """
  alias Loopyard.ChatAgent.MessageWindow

  @table :operator_jobs

  @doc "Record/refresh a dispatched job, anchoring read-position at now (dispatch = a look)."
  def note_dispatch(ws_id, agent_id) when is_binary(ws_id) and is_binary(agent_id) do
    put(ws_id, %{agent_id: agent_id, read_count: msg_count(agent_id)})
  end

  def note_dispatch(_, _), do: :ok

  @doc "You looked at it — re-anchor read-position to now (delta → 0)."
  def mark_read(ws_id) when is_binary(ws_id) do
    case get(ws_id) do
      %{agent_id: aid} = job -> put(ws_id, %{job | read_count: msg_count(aid)})
      _ -> :ok
    end
  end

  @doc "Remove a job from the queue (dismiss without looking)."
  def dismiss(ws_id) when is_binary(ws_id) do
    :ets.delete(@table, ws_id)
    :ok
  rescue
    _ -> :ok
  end

  @doc "All jobs: `[{ws_id, %{agent_id, read_count}}]`."
  def list do
    :ets.tab2list(@table)
  rescue
    _ -> []
  end

  @doc "New messages since you last looked (dispatched or dove in)."
  def delta(%{agent_id: aid, read_count: read}), do: max(0, msg_count(aid) - read)
  def delta(_), do: 0

  @doc "The job slot for a workspace, or nil. The slot a notification watches."
  def get(ws_id) when is_binary(ws_id), do: fetch(ws_id)

  defp fetch(ws_id) do
    case :ets.lookup(@table, ws_id) do
      [{^ws_id, job}] -> job
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp put(ws_id, job) do
    :ets.insert(@table, {ws_id, job})
    :ok
  rescue
    _ -> :ok
  end

  # Cheap: get_messages returns {window, TOTAL}; limit: 1 avoids materializing the
  # whole list just to count.
  defp msg_count(agent_id) do
    {_window, total} = MessageWindow.get_messages(agent_id, limit: 1)
    total
  rescue
    _ -> 0
  end
end
