defmodule Loopyard.Attention do
  @moduledoc """
  The **line** — every open decision across all agents, in one place: a
  question (`ask_user`/AskUserQuestion), a secret request, or an approval the
  agent is stuck waiting on a human for.

  A READ of `Loopyard.Notifications` — the decision subset of the inbox, in
  inbox order — decorated with each item's live card (`msg`) from the agent's
  ETS summary. This used to be a derived query (three broker tables plus a
  scan of every agent's whole message list) recomputed on every render of the
  dashboard, the rail and the deck, and inside every push payload; the store
  raises an item once and this is O(items). The item shape is unchanged so
  every caller keeps working.

  Grouping is by workspace (`counts_by_workspace/1`) — "this workspace has N
  blocking things" — with the operator's own items (no workspace) under `nil`.
  """
  alias Loopyard.Notifications
  alias Loopyard.Notifications.Item

  @type item :: %{
          id: String.t(),
          kind: :question | :secret | :approval,
          agent_id: String.t(),
          agent_name: String.t(),
          workspace_id: String.t() | nil,
          workspace_name: String.t() | nil,
          project_id: String.t() | nil,
          project_name: String.t() | nil,
          path: String.t(),
          msg: map() | nil,
          label: String.t(),
          asked_at: DateTime.t()
        }

  @doc """
  The line: open decisions across all agents, in inbox order (approvals, then
  questions, then secrets; newest first within a tier). `host` is accepted
  for call-site compatibility; paths no longer depend on it.
  """
  @spec line(String.t() | nil) :: [item()]
  def line(_host \\ nil) do
    Notifications.open(:decisions) |> Enum.map(&to_item/1)
  end

  @doc """
  Blocking-item count per workspace id (`nil` key = operator / no workspace).
  """
  @spec counts_by_workspace(String.t() | nil) :: %{optional(String.t() | nil) => pos_integer()}
  def counts_by_workspace(host \\ nil) do
    line(host)
    |> Enum.group_by(& &1.workspace_id)
    |> Map.new(fn {ws, items} -> {ws, length(items)} end)
  end

  @doc "Total number of open decisions."
  @spec count(String.t() | nil) :: non_neg_integer()
  def count(_host \\ nil), do: Notifications.count(:decisions)

  # --- internals ---

  defp to_item(%Item{} = n) do
    %{
      id: n.id,
      kind: n.kind,
      agent_id: n.agent_id,
      agent_name: n.agent_name || "Agent",
      workspace_id: n.workspace_id,
      workspace_name: n.workspace_name,
      project_id: n.project_id,
      project_name: n.project_name,
      path: n.path,
      msg: find_msg(n.agent_id, n.msg_id),
      label: n.label,
      asked_at: n.raised_at
    }
  end

  # The live card, from the agent's ETS summary (card patches already
  # applied — the canonical multiplayer read). One lookup per item; never a
  # GenServer call on a render path.
  defp find_msg(_agent_id, nil), do: nil

  defp find_msg(agent_id, msg_id) do
    case :ets.lookup(:chat_agents, agent_id) do
      [{^agent_id, summary}] -> Enum.find(Map.get(summary, :messages, []), &(&1[:id] == msg_id))
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
