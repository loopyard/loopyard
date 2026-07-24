defmodule Loopyard.Operator.Queue do
  @moduledoc """
  Builds the operator's attention queue: active agents → condensed items
  (project·workspace + state + what-it-needs), ranked by the configured
  `Operator.Policy`. Reuses `Birdseye.headline/1` for the state + "needs" line so
  the queue agrees with the rest of the app. ETS-cheap — pure over a
  `WorkspaceTree.global/0` tree, no shell-out.

  Phase 1 (minimal, visibility-first): the item shape is what the sidebar renders;
  `state` drives grouping, `needs` is the plain-language "what it needs from you".
  """
  alias LoopyardWeb.Components.Birdseye

  @recent_secs 30 * 60

  @doc "The ranked attention queue derived from a `WorkspaceTree.global/0` tree."
  @spec items(list()) :: [map()]
  def items(tree) when is_list(tree) do
    tree
    |> Enum.flat_map(fn p ->
      p.workspaces
      |> Enum.filter(&(&1.agents != []))
      |> Enum.map(&item(p, &1))
    end)
    |> Loopyard.Operator.Policy.rank()
  end

  def items(_), do: []

  defp item(project, ws) do
    headline = Birdseye.headline(ws)
    state = state(headline, ws)

    %{
      id: ws.id,
      project_id: project.id,
      project_name: project.name,
      workspace_name: ws.name,
      agent_id: primary_agent_id(ws),
      state: state,
      needs: needs(state, headline),
      last_activity_at: ws[:last_activity_at]
    }
  end

  # State from the app's existing priority headline (so the queue never disagrees
  # with the rail). blocked = needs you / broken; working = busy; else finished
  # (recently active) or idle (settled).
  defp state(%{kind: kind}, _ws) when kind in [:needs_you, :broken], do: :blocked
  defp state(%{kind: :working}, _ws), do: :working
  defp state(_headline, ws), do: if(recent?(ws[:last_activity_at]), do: :finished, else: :idle)

  defp needs(:blocked, %{text: text}), do: text
  defp needs(:working, %{text: text}), do: text
  defp needs(:working, _), do: "working…"
  defp needs(:finished, _), do: "ready for your next turn"
  defp needs(:idle, _), do: "idle"
  defp needs(_, _), do: ""

  defp recent?(%DateTime{} = at), do: DateTime.diff(DateTime.utc_now(), at) < @recent_secs
  defp recent?(_), do: false

  defp primary_agent_id(ws), do: (List.first(ws.agents) || %{})[:id]
end
