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

  The name's line ends with what the agent is DOING and when it last did
  something — the two facts a fleet is scanned for. They used to trail a single
  truncated line of where · harness · model · account, so on a phone the row
  read "Property Tax Analysis · main · Claude Co…" and the state was the part
  cut off. Below the name, muted: where it lives, what it runs on and as whom;
  it wraps to a second line on a narrow screen instead of losing its end.
  Uppercase group headings used to carry the where; a row that states its own
  where needs no heading, and the list stays flat — which is what the Agents
  root is for.

  Rows that need a human or have stopped moving (needs you, broken, at a plan
  limit, interrupted) sort to the top; the rest keep the registry's order
  (system agents first), so a row never jumps just because it started working.

  `rows/1` shapes summaries into what the row renders (ETS + registries
  only, no GenServer calls — this runs on mount paths).
  """
  use Phoenix.Component

  alias Loopyard.Fleet.Conditions
  alias LoopyardWeb.Components.{Birdseye, Common}
  alias LoopyardWeb.Live.WorkspaceLive.Components.ContextPanel

  @working [:thinking, :backoff, :compacting, :booting, :starting, :restarting]

  # States that want a human's eye, in the order they sort.
  @attention [:needs_you, :broken, :limited, :interrupted]

  @type row :: %{
          id: String.t(),
          name: String.t(),
          scope: :workspace | :system,
          where: String.t(),
          state: atom(),
          status: atom(),
          needs_you?: boolean(),
          word: String.t() | nil,
          loop: String.t() | nil,
          model: String.t() | nil,
          account: String.t() | nil,
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

    summaries
    |> Enum.map(fn s ->
      scope = Loopyard.Agents.scope(s)
      ws = Map.get(names, s[:workspace_id], %{})
      needs_you? = MapSet.member?(waiting, s.id)
      state = state_for(s, needs_you?)

      %{
        id: s.id,
        name: s[:name] || "Agent",
        scope: scope,
        where: where(scope, ws),
        state: state,
        word: word_for(state, s),
        status: s[:status],
        needs_you?: needs_you?,
        loop: loop_label(s[:harness]),
        model: ContextPanel.short_model(s[:model]),
        # Whose account (credentials) it runs under — who pays for its tokens.
        account: account_label(s[:workstation_identity]),
        activity: Birdseye.agent_activity(s),
        last_activity_at: s[:last_activity_at],
        path: path_for(s, scope, ws),
        group: where(scope, ws)
      }
    end)
    # Stable: only the attention rows move, in @attention's order.
    |> Enum.sort_by(&attention_rank(&1.state))
  end

  defp attention_rank(state),
    do: Enum.find_index(@attention, &(&1 == state)) || length(@attention)

  @doc """
  The fleet in one line: how many agents, then every state that has any, the
  ones wanting a human first — "6 agents · 1 needs you · 1 interrupted · 2 working".
  """
  @spec fleet_line([row()]) :: String.t()
  def fleet_line(rows) do
    counts = Enum.frequencies_by(rows, & &1.state)

    parts =
      for {state, label} <- [
            needs_you: "needs you",
            broken: "broken",
            limited: "at a plan limit",
            interrupted: "interrupted",
            working: "working"
          ],
          n = counts[state],
          do: "#{n} #{label}"

    Enum.join(["#{length(rows)} #{plural(length(rows), "agent")}" | parts], " · ")
  end

  defp plural(1, word), do: word
  defp plural(_, word), do: word <> "s"

  attr :row, :map, required: true
  attr :compact, :boolean, default: false, doc: "the home card's tighter row"

  def agent_row(assigns) do
    ~H"""
    <.link
      navigate={@row.path}
      class={[
        "flex items-start gap-2.5 -mx-2 px-2 hover:bg-zinc-100 dark:hover:bg-zinc-800/60 transition-colors",
        (@compact && "py-2") || "min-h-row py-2.5"
      ]}
    >
      <span
        class={["flex-none mt-[0.4rem] w-2 h-2 rounded-full", Common.state_light(@row.state)]}
        aria-hidden="true"
      ></span>
      <span class="min-w-0 flex-1">
        <span class="flex items-baseline gap-2">
          <span class="min-w-0 flex-1 truncate text-lead font-semibold text-zinc-900 dark:text-zinc-50">
            {@row.name}
          </span>
          <span class="flex-none text-meta whitespace-nowrap text-zinc-500 dark:text-zinc-400">
            <span :if={@row.word} class={["font-semibold", Common.status_class(@row.state)]}>
              {@row.word}
            </span>
            <span :if={@row.word && ago(@row.last_activity_at)} aria-hidden="true">·</span>
            {ago(@row.last_activity_at)}
          </span>
        </span>
        <span class={[
          "block text-meta text-zinc-500 dark:text-zinc-400",
          (@compact && "truncate") || "line-clamp-2 md:line-clamp-1"
        ]}>
          {meta_line(@row, @compact)}
        </span>
      </span>
    </.link>
    """
  end

  # Under the name, muted: where it lives, then (the root only — the home card
  # has no room) what it runs on and as whom.
  defp meta_line(row, compact?) do
    [
      row.where,
      if(!compact? && row.loop,
        do: Enum.join(Enum.reject([row.loop, row.model, row.account], &is_nil/1), " · ")
      )
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
      # Stopped without asking (Fleet.Conditions), in the inbox item's words.
      Conditions.of(s) in [:quarantined, :signed_out, :offline] -> :broken
      s[:status] == :rate_limited -> :limited
      # Restored from disk mid-turn and nothing continued it (AgentLog.at_rest/1).
      Conditions.of(s) == :interrupted -> :interrupted
      Conditions.of(s) == :failed_turn -> :broken
      s[:status] == :idle -> :done
      true -> :asleep
    end
  end

  # The state in the row's own words — nil for a resting one, which the dot
  # already covers (Common.notable_state?/1). A working agent names the tool
  # it's in when it has one.
  defp word_for(:needs_you, _s), do: "Needs you"
  defp word_for(:limited, _s), do: "At plan limit"

  defp word_for(state, s) when state in [:interrupted, :broken],
    do: Conditions.word(Conditions.of(s)) || "Broken"

  defp word_for(:working, s) do
    case Birdseye.agent_activity(s) do
      "working…" -> "Working"
      tool -> tool
    end
  end

  defp word_for(_state, _s), do: nil

  defp loop_label(nil), do: nil
  defp loop_label(harness), do: Loopyard.Harness.Catalog.label(harness)

  # The same label the chat's prompt bands and header chip use for the identity.
  defp account_label(id) when is_binary(id) and id != "",
    do:
      LoopyardWeb.Live.WorkspaceLive.Components.Chat.Status.workstation_label(%{
        workstation_identity: id
      })

  defp account_label(_), do: nil

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
