defmodule LoopyardWeb.AgentsLive.Row do
  @moduledoc """
  One agent as a row — the shared shape for the Agents root and the home
  card.

  The NAME leads, at one left edge for every row. Where the agent lives is
  secondary and muted after it; what it's doing sits opposite. The first cut
  led with the project · workspace chip at full strength, truncated to 40% of
  the row, so the secondary fact was the loudest thing on it and every name
  started at a different x.

  This two-line row IS the agent atom, and it is deliberately not a workspace
  row: a workspace reads as one quiet line of project · workspace, an agent as
  a BOLD NAME with its status beneath. Wherever agents are listed they wear
  this shape, so "a list of agents" is recognisable before you read a word.

  Everything below the name is one muted line: where it lives, what it runs
  on, what it's doing, how long ago. Uppercase group headings used to carry
  the where; a row that states its own where needs no heading, and the list
  stays flat — which is what the Agents root is for.

  `rows/1` shapes summaries into what the row renders (ETS + registries
  only, no GenServer calls — this runs on mount paths).
  """
  use Phoenix.Component

  alias LoopyardWeb.Components.{Birdseye, Common}

  @working [:thinking, :backoff, :compacting, :booting, :starting, :restarting]

  @type row :: %{
          id: String.t(),
          name: String.t(),
          scope: :workspace | :system,
          where: String.t(),
          state: atom(),
          status: atom(),
          needs_you?: boolean(),
          loop: String.t() | nil,
          model: String.t() | nil,
          activity: String.t(),
          last_activity_at: DateTime.t() | nil,
          path: String.t(),
          group: String.t()
        }

  @doc """
  Shape agent summaries into rows. `waiting` is the set of agent ids with an
  open decision on the inbox.
  """
  @spec rows([map()], MapSet.t()) :: [row()]
  def rows(summaries, waiting \\ MapSet.new()) do
    names = workspace_names()

    Enum.map(summaries, fn s ->
      scope = Loopyard.Agents.scope(s)
      ws = Map.get(names, s[:workspace_id], %{})
      needs_you? = MapSet.member?(waiting, s.id)

      %{
        id: s.id,
        name: s[:name] || "Agent",
        scope: scope,
        where: where(scope, ws),
        state: state_for(s, needs_you?),
        status: s[:status],
        needs_you?: needs_you?,
        loop: loop_label(s[:harness]),
        model: s[:model],
        activity: Birdseye.agent_activity(s),
        last_activity_at: s[:last_activity_at],
        path: path_for(s, scope, ws),
        group: where(scope, ws)
      }
    end)
  end

  attr :row, :map, required: true
  attr :compact, :boolean, default: false, doc: "the home card's tighter row"

  def agent_row(assigns) do
    ~H"""
    <.link
      navigate={@row.path}
      class={[
        "flex items-start gap-2.5 -mx-2 px-2 hover:bg-zinc-100 dark:hover:bg-zinc-800/60 transition-colors",
        (@compact && "py-2") || "min-h-[3.25rem] py-2.5"
      ]}
    >
      <span
        class={["flex-none mt-[0.4rem] w-2 h-2 rounded-full", Common.state_light(@row.state)]}
        aria-hidden="true"
      ></span>
      <span class="min-w-0 flex-1">
        <span class="block truncate text-lead font-semibold text-zinc-900 dark:text-zinc-50">
          {@row.name}
        </span>
        <span class="block truncate text-meta text-zinc-500 dark:text-zinc-400">
          {meta_line(@row, @compact)}
        </span>
      </span>
      <span
        :if={@row.needs_you?}
        class="flex-none text-meta font-semibold uppercase tracking-wide text-orange-700 dark:text-orange-400 whitespace-nowrap"
      >
        Needs you
      </span>
    </.link>
    """
  end

  # Everything under the name, in one muted line: where it lives, what it
  # runs on (the root only — the home card has no room), what it's doing and
  # when it last did something.
  defp meta_line(row, compact?) do
    [
      row.where,
      if(!compact? && row.loop,
        do: Enum.join(Enum.reject([row.loop, row.model], &is_nil/1), " · ")
      ),
      if(row.needs_you?, do: nil, else: row.activity),
      if(!compact?, do: ago(row.last_activity_at))
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  # Where an agent lives, as ONE string: a system agent is "System", a
  # workspace agent "project · workspace".
  defp where(:system, _ws), do: "System"

  defp where(_scope, ws) do
    [ws[:project_name] || "Workspace", ws[:workspace_name]]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  @doc "How many rows are working right now."
  def working_count(rows), do: Enum.count(rows, &(&1.status in @working))

  defp state_for(s, needs_you?) do
    cond do
      needs_you? -> :needs_you
      s[:status] in @working -> :working
      s[:status] == :auth_expired or s[:quarantined] -> :broken
      s[:status] == :idle -> :done
      true -> :asleep
    end
  end

  defp loop_label(nil), do: nil
  defp loop_label(harness), do: Loopyard.Harness.Catalog.label(harness)

  defp path_for(s, :system, _ws), do: "/agents/#{s.id}"

  defp path_for(s, :workspace, %{project_id: pid}) when is_binary(pid),
    do: "/projects/#{pid}/workspaces/#{s.workspace_id}/agents/#{s.id}"

  defp path_for(s, _scope, _ws), do: "/agents/#{s.id}"

  defp workspace_names do
    for p <- Loopyard.ProjectRegistry.list_projects(),
        ws <- Loopyard.WorkspaceRegistry.list_workspaces(p.id),
        into: %{} do
      {ws.id, %{project_id: p.id, project_name: p.name, workspace_name: ws.name}}
    end
  rescue
    _ -> %{}
  catch
    _, _ -> %{}
  end

  defp ago(%DateTime{} = at) do
    secs = DateTime.diff(DateTime.utc_now(), at)

    cond do
      secs < 60 -> "moments ago"
      secs < 3600 -> "#{div(secs, 60)}m ago"
      secs < 86_400 -> "#{div(secs, 3600)}h ago"
      true -> "#{div(secs, 86_400)}d ago"
    end
  end

  defp ago(_), do: nil
end
