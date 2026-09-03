defmodule LoopyardWeb.AgentsLive.Row do
  @moduledoc """
  One agent as a row — the shared shape for the Agents root and the home
  card.

  The NAME leads, at one left edge for every row. Where the agent lives is
  secondary and muted after it; what it's doing sits opposite. The first cut
  led with the project · workspace chip at full strength, truncated to 40% of
  the row, so the secondary fact was the loudest thing on it and every name
  started at a different x.

  On the Agents root the rows are GROUPED by project · workspace, so a row
  drops the where entirely — the group heading says it. The home card is
  ungrouped (`compact`), so there the where rides along after the name.

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
        "flex items-center gap-2.5 -mx-2 px-2 hover:bg-zinc-100 dark:hover:bg-zinc-800/60 transition-colors",
        (@compact && "py-2 md:py-1.5") || "min-h-[3.25rem] sm:min-h-11 py-2"
      ]}
    >
      <span
        class={["flex-none w-2 h-2 rounded-full", Common.state_light(@row.state)]}
        aria-hidden="true"
      ></span>
      <span class="min-w-0 flex-1 flex items-baseline gap-2">
        <span class="flex-none max-w-[60%] truncate text-lead font-medium text-zinc-900 dark:text-zinc-50">
          {@row.name}
        </span>
        <span :if={@compact} class="min-w-0 truncate text-meta text-zinc-500 dark:text-zinc-400">
          {@row.where}
        </span>
        <span
          :if={!@compact && @row.loop}
          class="hidden md:inline min-w-0 truncate text-meta text-zinc-400 dark:text-zinc-500"
        >
          {@row.loop}<span :if={@row.model}> · {@row.model}</span>
        </span>
      </span>
      <span class="flex-none inline-flex items-center gap-2 text-meta text-zinc-500 dark:text-zinc-400 whitespace-nowrap">
        <span :if={@row.needs_you?} class="font-semibold text-orange-700 dark:text-orange-400">Needs you</span>
        <span :if={!@row.needs_you?}>{@row.activity}</span>
        <span :if={!@compact && @row.last_activity_at} class="hidden md:inline">· {ago(
          @row.last_activity_at
        )}</span>
      </span>
    </.link>
    """
  end

  # Where an agent lives, as ONE string: a system agent is "System", a
  # workspace agent "project · workspace". Also the group heading on the
  # Agents root, so a row and its group can never disagree.
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
