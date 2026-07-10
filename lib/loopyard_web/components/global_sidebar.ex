defmodule LoopyardWeb.Components.GlobalSidebar do
  @moduledoc """
  The god-mode left rail (#55) as an **expandable tree**, not a drill-down.

  Every project → workspace → agent is one tree. You expand the branches you
  care about — several open at once for a god-view across projects — and
  collapse the ones you don't. Not a flat pile of links (collapsed by default,
  so there's hierarchy), not a one-level-at-a-time drill (you keep as many
  branches open as you like). Which nodes are open is held in the LiveView
  (`@expanded`, a `MapSet` of node keys) so it's server-driven and survives
  navigation; rows fire `sidebar_toggle` to open/close, agent rows navigate.

  Fed by `Loopyard.WorkspaceTree.global/0`, kept live by subscribing to
  `Loopyard.Events.Activity` in the host LiveView.
  """
  use Phoenix.Component

  # Reuse the ONE canonical status normalizer + dot colors the right pane uses,
  # so the same agent never shows two different colors in two places.
  alias LoopyardWeb.Components.Sidebar

  attr :tree, :list, required: true
  attr :expanded, :any, default: nil
  attr :current_workspace_id, :string, default: nil
  attr :class, :string, default: nil

  def global_sidebar(assigns) do
    assigns = assign_new(assigns, :expanded, fn -> MapSet.new() end)

    ~H"""
    <nav class={["flex flex-col", @class]} aria-label="Navigation">
      <%!-- Persistent home: the wordmark always returns to the root screen.
           Fixed height so nothing shifts. --%>
      <.link
        navigate="/"
        class="flex items-center gap-2.5 h-14 px-4 flex-none border-b border-zinc-200/70 dark:border-zinc-800 hover:bg-zinc-100/60 dark:hover:bg-zinc-800/40 transition-colors group"
      >
        <span class="grid place-items-center w-7 h-7 rounded-lg bg-violet-600 text-white shadow-sm shadow-violet-600/30 group-hover:scale-105 transition-transform">
          <svg viewBox="0 0 20 20" fill="currentColor" class="w-4 h-4"><path d="M10 2.5 3 6v8l7 3.5L17 14V6l-7-3.5Zm0 1.9 4.7 2.35L10 9.1 5.3 6.75 10 4.4Z" /></svg>
        </span>
        <span class="font-semibold tracking-tight text-zinc-900 dark:text-zinc-50">Loopyard</span>
      </.link>

      <div class="flex-1 overflow-y-auto py-1.5">
        <div :if={@tree == []} class="px-3 py-2 text-xs text-zinc-400 italic">
          no projects yet
        </div>

        <%!-- PROJECT branch → its WORKSPACES. Two levels, that's it: no agents,
             no services in the rail. Each workspace is a link with a status
             dot aggregated from its agents. --%>
        <div :for={project <- @tree} class="select-none">
          <.branch_row
            key={"p:#{project.id}"}
            expanded={MapSet.member?(@expanded, "p:#{project.id}")}
            name={project.name}
            dot={aggregate_dot(all_agents(project))}
            count={workspace_count_label(project.workspaces)}
            depth={0}
          />

          <div :if={MapSet.member?(@expanded, "p:#{project.id}")}>
            <.link
              :for={ws <- project.workspaces}
              navigate={"/projects/#{project.id}/workspaces/#{ws.id}"}
              class={[
                "flex items-center gap-2.5 pr-3 py-1.5 mx-1 rounded-md",
                "hover:bg-zinc-200/60 dark:hover:bg-zinc-700/40",
                ws.id == @current_workspace_id && "bg-violet-100 dark:bg-violet-500/15"
              ]}
              style="padding-left: 2rem"
            >
              <span class={["h-2 w-2 flex-none rounded-full", aggregate_dot(ws.agents)]} />
              <span class="truncate text-sm text-zinc-700 dark:text-zinc-200">{ws.name}</span>
            </.link>

            <div
              :if={project.workspaces == []}
              class="py-1.5 text-xs text-zinc-400 italic"
              style="padding-left: 2rem"
            >
              no workspaces
            </div>

            <.link
              navigate={"/projects/#{project.id}/new"}
              class="flex items-center py-1.5 text-xs text-zinc-400 hover:text-violet-500 dark:hover:text-violet-400"
              style="padding-left: 2rem"
            >
              + new workspace
            </.link>
          </div>
        </div>
      </div>
    </nav>
    """
  end

  # A collapsible project/workspace row: chevron (rotates when open) + status
  # dot + name + agent count. `depth` sets the indent so the tree reads.
  attr :key, :string, required: true
  attr :expanded, :boolean, required: true
  attr :name, :string, required: true
  attr :dot, :string, default: nil
  attr :count, :string, default: nil
  attr :depth, :integer, required: true

  defp branch_row(assigns) do
    assigns = assign(assigns, :pad, "padding-left: #{0.75 + assigns.depth * 1.25}rem")

    ~H"""
    <button
      type="button"
      phx-click="sidebar_toggle"
      phx-value-node={@key}
      style={@pad}
      class="w-full flex items-center gap-2 pr-2 py-2 mx-1 rounded-md text-left hover:bg-zinc-200/60 dark:hover:bg-zinc-700/40"
      aria-expanded={to_string(@expanded)}
    >
      <svg
        viewBox="0 0 20 20"
        fill="currentColor"
        class={[
          "w-3.5 h-3.5 flex-none text-zinc-400 transition-transform",
          @expanded && "rotate-90"
        ]}
      >
        <path
          fill-rule="evenodd"
          d="M7.21 14.77a.75.75 0 0 1 0-1.06L10.94 10 7.21 6.29a.75.75 0 1 1 1.06-1.06l4.25 4.24a.75.75 0 0 1 0 1.06l-4.25 4.24a.75.75 0 0 1-1.06 0Z"
          clip-rule="evenodd"
        />
      </svg>
      <span :if={@dot} class={["h-2 w-2 flex-none rounded-full", @dot]} />
      <span class={[
        "truncate text-sm",
        @depth == 0 && "font-semibold text-zinc-800 dark:text-zinc-100",
        @depth > 0 && "font-medium text-zinc-700 dark:text-zinc-200"
      ]}>
        {@name}
      </span>
      <span :if={@count} class="ml-auto text-xs text-zinc-400 tabular-nums flex-none">
        {@count}
      </span>
    </button>
    """
  end

  @doc """
  Default-open set for a project you just landed in: expand that project so its
  workspaces are listed, everything else collapsed.
  """
  def initial_expanded(nil), do: MapSet.new()
  def initial_expanded(project_id), do: MapSet.new(["p:#{project_id}"])

  @doc "Toggle a node key in the expanded set."
  def toggle(expanded, key) do
    if MapSet.member?(expanded, key),
      do: MapSet.delete(expanded, key),
      else: MapSet.put(expanded, key)
  end

  # ── Display helpers ──

  defp all_agents(project), do: Enum.flat_map(project.workspaces, & &1.agents)

  defp workspace_count_label([]), do: nil
  defp workspace_count_label(workspaces), do: "#{length(workspaces)}"

  # Aggregate dot for a collapsed branch: loudest DISPLAY state wins, using the
  # exact same normalizer as each agent leaf so a parent's dot always agrees
  # with the children it summarizes. Red > working > ready > sleeping.
  defp aggregate_dot([]), do: nil

  defp aggregate_dot(agents) do
    displays = Enum.map(agents, &Sidebar.agent_display_status/1)

    cond do
      Enum.any?(displays, &(&1 in [:crashed, :quarantined])) -> Sidebar.status_dot(:crashed)
      Enum.any?(displays, &(&1 == :thinking)) -> Sidebar.status_dot(:thinking)
      Enum.any?(displays, &(&1 == :ready)) -> Sidebar.status_dot(:ready)
      true -> Sidebar.status_dot(:sleeping)
    end
  end
end
