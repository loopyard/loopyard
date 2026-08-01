defmodule Loopyard.Attention do
  @moduledoc """
  The **town-hall line** — every live blocking item across all agents, in one
  place. A blocking item is anything an agent is stuck waiting on a human for: a
  question (`ask_user`/AskUserQuestion), a secret request, or a blocking
  approval. Agents "form a line at the mic"; you walk the line answering.

  **Self-decaying by construction.** The underlying broker stores
  (`Harness.Questions` / `SecretRequests` / `Approvals`) reap dead or timed-out
  waiters as they are read (`pending_all/0`), so a question nobody answers inside
  its TTL simply ages out of the line — a stall clears itself, no error, no
  manual cleanup. Reading the line is what advances the decay.

  ETS-cheap: a linear scan of three small tables + one `get_state` per agent that
  actually has a pending item. Safe to call on every render / activity tick.

  Grouping is by workspace (`counts_by_workspace/1`) — "this workspace has N
  blocking things" — with the operator's own items (no workspace) under `nil`.
  """
  alias Loopyard.{ChatAgent, WorkspaceTree}
  alias Loopyard.Harness.{Questions, SecretRequests, Approvals}

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
  The line: blocking items across all agents, oldest-first (first hand up, first
  at the mic). Pass the request host so workspace links resolve correctly.
  """
  @spec line(String.t() | nil) :: [item()]
  def line(host \\ nil) do
    raw = raw_items()

    # CONCURRENTLY. get_state/1 is a GenServer call with a 500ms cap, so
    # resolving N agents serially made this O(N x 500ms) in the worst case —
    # and this function is on the mount path for the dashboard AND the operator
    # rail. One wedged agent used to delay every other agent's lookup behind
    # it; now a slow one only spends its own budget.
    states =
      raw
      |> Enum.map(fn {_kind, _id, e} -> e.agent_id end)
      |> Enum.uniq()
      |> Task.async_stream(&{&1, safe_state(&1)},
        max_concurrency: 16,
        timeout: 1_000,
        on_timeout: :kill_task,
        ordered: false
      )
      |> Enum.reduce(%{}, fn
        {:ok, {aid, state}}, acc -> Map.put(acc, aid, state)
        {:exit, _}, acc -> acc
      end)

    ws_lookup = workspace_lookup(host)

    raw
    |> Enum.map(&decorate(&1, states, ws_lookup))
    |> Enum.sort_by(& &1.asked_at, DateTime)
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

  @doc "Total number of agents waiting at the mic."
  @spec count(String.t() | nil) :: non_neg_integer()
  def count(host \\ nil), do: line(host) |> length()

  # --- internals ---

  defp raw_items do
    ets =
      Enum.map(Questions.pending_all(), fn {id, e} -> {:question, id, e} end) ++
        Enum.map(SecretRequests.pending_all(), fn {id, e} -> {:secret, id, e} end) ++
        Enum.map(Approvals.pending_all(), fn {id, e} -> {:approval, id, e} end)

    # UNION with pending CARDS from the durable message store: broker entries
    # are ephemeral (waiter pruning, restarts), but the card is the truth —
    # "For you" must show every open question even when its entry is gone.
    seen = MapSet.new(ets, fn {_k, _id, e} -> {e.agent_id, e[:msg_id]} end)

    cards =
      for %{id: aid} = st <- agent_summaries(),
          # Only the recent tail: pending cards live near it, and this scan runs
          # on every rail tick / Reviewer refresh — full-history scans across the
          # fleet made typing jank (client saw 250ms+ main-thread gaps).
          msg <- st |> Map.get(:messages, []) |> Enum.take(-200),
          msg[:status] == :pending,
          kind = card_kind(msg[:role]),
          kind != nil,
          not MapSet.member?(seen, {aid, msg[:id]}) do
        {kind, msg[:question_id] || msg[:approval_id] || msg[:request_id] || msg[:id],
         %{
           agent_id: aid,
           msg_id: msg[:id],
           questions: msg[:questions] || [],
           name: msg[:name]
         }}
      end

    ets ++ cards
  end

  defp card_kind(:question), do: :question
  defp card_kind(:secret_request), do: :secret
  defp card_kind(:approval), do: :approval
  defp card_kind(_), do: nil

  defp agent_summaries do
    # Pure-ETS read — list_agents/0 freshens each summary with a 500ms
    # GenServer call per agent, which this every-rail-tick scan must not pay.
    Loopyard.ChatAgent.list_agent_summaries()
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp decorate({kind, id, entry}, states, ws_lookup) do
    st = Map.get(states, entry.agent_id)
    msg = find_msg(st, entry[:msg_id])
    ws_id = st && Map.get(st, :workspace_id)
    ws = Map.get(ws_lookup, ws_id, %{})

    %{
      id: id,
      kind: kind,
      agent_id: entry.agent_id,
      agent_name: (st && Map.get(st, :name)) || "Agent",
      workspace_id: ws_id,
      workspace_name: Map.get(ws, :workspace_name),
      project_id: Map.get(ws, :project_id),
      project_name: Map.get(ws, :project_name),
      path: path(ws_id, ws, entry.agent_id),
      msg: msg,
      label: label(kind, entry, msg),
      asked_at: asked_at(msg)
    }
  end

  defp find_msg(nil, _), do: nil
  defp find_msg(_st, nil), do: nil
  defp find_msg(st, msg_id), do: st |> Map.get(:messages, []) |> Enum.find(&(&1.id == msg_id))

  defp asked_at(%{timestamp: %DateTime{} = t}), do: t
  defp asked_at(_), do: DateTime.from_unix!(0)

  defp label(:question, entry, _msg) do
    case entry[:questions] do
      [%{prompt: p} | rest] when is_binary(p) and p != "" ->
        if rest == [], do: p, else: "#{p} (+#{length(rest)} more)"

      _ ->
        "A question"
    end
  end

  defp label(:secret, entry, _msg), do: "Secret: #{entry[:name] || "value"}"
  defp label(:approval, _entry, %{action: %{verb: verb}}), do: "Approval: #{verb}"
  defp label(:approval, _entry, _msg), do: "Approval requested"

  # Where answering this item lives. Workspace agents → their chat; the operator
  # (no workspace) → /operator.
  defp path(nil, _ws, _agent_id), do: "/operator"

  defp path(ws_id, %{project_id: pid}, agent_id) when is_binary(pid),
    do: "/projects/#{pid}/workspaces/#{ws_id}/agents/#{agent_id}"

  defp path(_ws_id, _ws, _agent_id), do: "/operator"

  defp workspace_lookup(host) do
    for p <- WorkspaceTree.global(host), ws <- p.workspaces, into: %{} do
      {ws.id, %{project_id: p.id, project_name: p.name, workspace_name: ws.name}}
    end
  rescue
    _ -> %{}
  end

  # get_state is a 500ms GenServer call with an ETS fallback (a wedged agent must
  # not hang the queue). Belt-and-suspenders around it here too.
  defp safe_state(agent_id) do
    ChatAgent.get_state(agent_id)
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end
end
