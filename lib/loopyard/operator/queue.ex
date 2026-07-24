defmodule Loopyard.Operator.Queue do
  @moduledoc """
  Builds the operator's WORKING list for display: every workspace with agent
  activity in the last `@recency_hours`, joined with the live `WorkspaceTree` for
  names + state, most-recent first. Not just what the operator dispatched — work
  you drive directly counts too. The "delta since you last looked" is attached
  where an `Operator.Jobs` read-position exists.

  This used to be a dispatch-only inbox that retired a job the moment you'd read
  its result (`:done` + delta 0 → dropped), which left the list empty right after
  you glanced at things. A recency window is what you actually want: a rolling
  view of recent work, not an inbox that empties itself.

  States (from the live agent status): `:needs_you` (asked a question / broken),
  `:chugging` (busy), `:done` (idle). ETS-cheap — no shell-out.
  """
  alias LoopyardWeb.Components.Birdseye
  alias Loopyard.Operator.Jobs

  @recency_hours 48

  @doc "Workspaces active within the recency window, newest first, with delta."
  @spec items(list(), DateTime.t()) :: [map()]
  def items(tree, now \\ DateTime.utc_now())

  def items(tree, now) when is_list(tree) do
    jobs = Jobs.list() |> Map.new()

    for(p <- tree, ws <- p.workspaces, do: {p, ws})
    |> Enum.filter(fn {_p, ws} -> recent?(ws[:last_activity_at], now) end)
    |> Enum.flat_map(fn {p, ws} ->
      case primary_agent(ws, Map.get(jobs, ws.id)) do
        nil -> []
        agent_id -> [item(p, ws, Map.get(jobs, ws.id), agent_id)]
      end
    end)
    |> Enum.sort_by(&recency/1, :desc)
  end

  def items(_, _), do: []

  defp item(project, ws, job, agent_id) do
    headline = Birdseye.headline(ws)
    state = state(headline, ws)

    %{
      id: ws.id,
      project_id: project.id,
      project_name: project.name,
      workspace_name: ws.name,
      agent_id: agent_id,
      state: state,
      delta: if(job, do: Jobs.delta(job), else: 0),
      needs: needs(state, headline),
      last_activity_at: ws[:last_activity_at]
    }
  end

  # Prefer the dispatched job's agent (the read-position is anchored to it);
  # otherwise the workspace's first live agent (directly-driven work).
  defp primary_agent(_ws, %{agent_id: aid}) when is_binary(aid), do: aid

  defp primary_agent(ws, _job) do
    case ws[:agents] do
      [%{id: id} | _] -> id
      _ -> nil
    end
  end

  defp recent?(%DateTime{} = at, now), do: DateTime.diff(now, at, :hour) <= @recency_hours
  defp recent?(_, _), do: false

  defp recency(%{last_activity_at: %DateTime{} = at}), do: DateTime.to_unix(at)
  defp recency(_), do: 0

  # Derive the state from the app's existing priority headline + agent status.
  defp state(%{kind: kind}, _ws) when kind in [:needs_you, :broken], do: :needs_you
  defp state(%{kind: :working}, _ws), do: :chugging
  defp state(_headline, _ws), do: :done

  defp needs(:needs_you, %{text: text}), do: text
  defp needs(:chugging, %{text: text}), do: text
  defp needs(:chugging, _), do: "working…"
  defp needs(:done, _), do: "done"
  defp needs(_, _), do: ""
end
