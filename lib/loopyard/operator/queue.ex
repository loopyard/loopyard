defmodule Loopyard.Operator.Queue do
  @moduledoc """
  Builds the operator's WORKER QUEUE for display: one card per DISPATCHED job
  (`Operator.Jobs`), joined with the live `WorkspaceTree` for names + state, with
  the "delta since you last looked" attached. Ranked by `Operator.Policy`.

  Lifecycle states (derived from the live agent status): `:chugging` (busy),
  `:needs_you` (asked a question / hit a gate), `:done` (idle after your
  dispatch). Inbox retirement: a `:done` job with a 0 delta (you've read it)
  drops out. ETS-cheap — no shell-out.
  """
  alias LoopyardWeb.Components.Birdseye
  alias Loopyard.Operator.Jobs

  @doc "The ranked worker queue: dispatched jobs (with delta), minus read+done."
  @spec items(list()) :: [map()]
  def items(tree) when is_list(tree) do
    lookup = for(p <- tree, ws <- p.workspaces, into: %{}, do: {ws.id, {p, ws}})

    Jobs.list()
    |> Enum.flat_map(fn {ws_id, job} ->
      case Map.get(lookup, ws_id) do
        {project, ws} -> [item(project, ws, job)]
        _ -> []
      end
    end)
    |> Enum.reject(&hidden?/1)
    |> Loopyard.Operator.Policy.rank()
  end

  def items(_), do: []

  defp item(project, ws, job) do
    headline = Birdseye.headline(ws)
    state = state(headline, ws)

    %{
      id: ws.id,
      project_id: project.id,
      project_name: project.name,
      workspace_name: ws.name,
      agent_id: job.agent_id,
      state: state,
      delta: Jobs.delta(job),
      needs: needs(state, headline),
      last_activity_at: ws[:last_activity_at]
    }
  end

  # Derive the job state from the app's existing priority headline + agent status.
  defp state(%{kind: kind}, _ws) when kind in [:needs_you, :broken], do: :needs_you
  defp state(%{kind: :working}, _ws), do: :chugging
  defp state(_headline, _ws), do: :done

  # Inbox retirement: a done job you've already read (delta 0) drops out. Chugging
  # and needs-you always stay; a done job with unread work stays.
  defp hidden?(%{state: :done, delta: 0}), do: true
  defp hidden?(_), do: false

  defp needs(:needs_you, %{text: text}), do: text
  defp needs(:chugging, %{text: text}), do: text
  defp needs(:chugging, _), do: "working…"
  defp needs(:done, _), do: "done"
  defp needs(_, _), do: ""
end
