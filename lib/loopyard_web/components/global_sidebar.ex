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

  # Share the birdseye visual language with the home page: same status dots,
  # same aggregate logic, same openable port chip — so moving between the rail
  # and the home page feels like one system, and the same agent never shows two
  # different colors in two places.
  alias LoopyardWeb.Components.Birdseye

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
          <.project_row
            key={"p:#{project.id}"}
            expanded={MapSet.member?(@expanded, "p:#{project.id}")}
            name={project.name}
          />

          <div :if={MapSet.member?(@expanded, "p:#{project.id}")}>
            <%!-- Two columns: [agent dot + workspace name] ......... [ :port ].
                 The port chip is a SIBLING of the row link (not nested inside
                 it) — nested <a> tags are invalid and get kicked out of the
                 row. --%>
            <div
              :for={ws <- project.workspaces}
              class={[
                "group flex items-center pr-2 mx-1 rounded-md",
                "hover:bg-zinc-200/60 dark:hover:bg-zinc-700/40",
                ws.id == @current_workspace_id && "bg-violet-100 dark:bg-violet-500/15"
              ]}
            >
              <.link
                navigate={"/projects/#{project.id}/workspaces/#{ws.id}"}
                class="flex-1 min-w-0 flex items-center gap-2.5 py-1.5"
                style="padding-left: 2rem"
              >
                <Birdseye.dot class={Birdseye.aggregate_dot(ws.agents)} size={:sm} />
                <span class="truncate text-sm text-zinc-700 dark:text-zinc-200">{ws.name}</span>
              </.link>
              <Birdseye.port_chip :for={p <- ws.ports} port={p.port} url={p.url} />
            </div>

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

  # A project row: a chevron (rotates when open) + the project name in bold.
  # Deliberately NO status dot — a project has no status of its own; its
  # workspaces do. The chevron + weight is what marks it as a project, so it
  # never reads like a workspace.
  attr :key, :string, required: true
  attr :expanded, :boolean, required: true
  attr :name, :string, required: true

  defp project_row(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="sidebar_toggle"
      phx-value-node={@key}
      class="w-full flex items-center gap-2 pl-2 pr-2 py-2 mx-1 rounded-md text-left hover:bg-zinc-200/60 dark:hover:bg-zinc-700/40"
      aria-expanded={to_string(@expanded)}
    >
      <svg
        viewBox="0 0 20 20"
        fill="currentColor"
        class={[
          "w-4 h-4 flex-none text-zinc-400 transition-transform",
          @expanded && "rotate-90"
        ]}
      >
        <path
          fill-rule="evenodd"
          d="M7.21 14.77a.75.75 0 0 1 0-1.06L10.94 10 7.21 6.29a.75.75 0 1 1 1.06-1.06l4.25 4.24a.75.75 0 0 1 0 1.06l-4.25 4.24a.75.75 0 0 1-1.06 0Z"
          clip-rule="evenodd"
        />
      </svg>
      <span class="truncate text-sm font-semibold text-zinc-800 dark:text-zinc-100">
        {@name}
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
end
