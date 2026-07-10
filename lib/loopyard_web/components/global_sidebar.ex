defmodule LoopyardWeb.Components.GlobalSidebar do
  @moduledoc """
  The god-mode left rail (#55) as a **drill-down**, not a flat pile of links.

  One comfortable level at a time — Projects → a project's Workspaces → a
  workspace's Agents — with a back button to zoom out fast. Real hierarchy
  without shrinking anything to fit. The current level is chosen by `@focus`
  (held in the LiveView so it's server-driven); rows fire `sidebar_*` events to
  drill / go back, and agent rows navigate. Single-workspace projects skip
  straight to their agents (one less click for the common case).

  Fed by `Loopyard.WorkspaceTree.global/0`, kept live by subscribing to
  `Loopyard.Events.Activity` in the host LiveView.
  """
  use Phoenix.Component

  attr :tree, :list, required: true
  attr :focus, :any, default: nil
  attr :current_agent_id, :string, default: nil
  attr :class, :string, default: nil

  def global_sidebar(assigns) do
    assigns = assign(assigns, :view, resolve_view(assigns.tree, assigns.focus))

    ~H"""
    <nav class={["flex flex-col", @class]} aria-label="Navigation">
      <%!-- Persistent home: the wordmark always returns to the root screen (the
           job the breadcrumb used to do). Fixed height so nothing shifts. --%>
      <.link
        navigate="/"
        class="flex items-center gap-2.5 h-14 px-4 flex-none border-b border-zinc-200/70 dark:border-zinc-800 hover:bg-zinc-100/60 dark:hover:bg-zinc-800/40 transition-colors group"
      >
        <span class="grid place-items-center w-7 h-7 rounded-lg bg-violet-600 text-white shadow-sm shadow-violet-600/30 group-hover:scale-105 transition-transform">
          <svg viewBox="0 0 20 20" fill="currentColor" class="w-4 h-4"><path d="M10 2.5 3 6v8l7 3.5L17 14V6l-7-3.5Zm0 1.9 4.7 2.35L10 9.1 5.3 6.75 10 4.4Z" /></svg>
        </span>
        <span class="font-semibold tracking-tight text-zinc-900 dark:text-zinc-50">Loopyard</span>
      </.link>

      <%!-- Drill context: where you are + a back chevron to zoom out. Fixed
           height so the row list below never jumps between levels. --%>
      <div class="flex items-center gap-1 h-10 px-2 flex-none border-b border-zinc-200/50 dark:border-zinc-800/70">
        <button
          :if={@view.back}
          type="button"
          phx-click="sidebar_back"
          class="inline-flex items-center rounded-md px-1.5 py-1 text-zinc-500 hover:text-zinc-900 dark:hover:text-zinc-100 hover:bg-zinc-200/60 dark:hover:bg-zinc-700/40 transition-colors"
          aria-label="Back"
        >
          <svg viewBox="0 0 20 20" fill="currentColor" class="w-4 h-4"><path
            fill-rule="evenodd"
            d="M12.79 5.23a.75.75 0 0 1 0 1.06L9.06 10l3.73 3.71a.75.75 0 1 1-1.06 1.06l-4.25-4.24a.75.75 0 0 1 0-1.06l4.25-4.24a.75.75 0 0 1 1.06 0Z"
            clip-rule="evenodd"
          /></svg>
        </button>
        <span class="truncate text-[11px] font-semibold uppercase tracking-[0.08em] text-zinc-500 dark:text-zinc-400 px-1">
          {@view.title}
        </span>
      </div>

      <div class="flex-1 overflow-y-auto py-1.5">
        <%!-- Agent rows navigate; project/workspace rows drill in. --%>
        <.link
          :for={row <- @view.rows}
          :if={row.kind == :agent}
          navigate={row.path}
          class={[
            "flex items-center gap-2.5 px-3 py-2 mx-1 rounded-md",
            "hover:bg-zinc-200/60 dark:hover:bg-zinc-700/40",
            row.id == @current_agent_id && "bg-violet-100 dark:bg-violet-500/15"
          ]}
        >
          <span class={["h-2.5 w-2.5 flex-none rounded-full", status_dot(row.status)]} />
          <span class="truncate text-sm text-zinc-700 dark:text-zinc-200">{row.name}</span>
          <span :if={row.active_tool} class="ml-auto truncate text-xs text-zinc-400 font-mono">
            {row.active_tool}
          </span>
        </.link>

        <button
          :for={row <- @view.rows}
          :if={row.kind != :agent}
          type="button"
          phx-click={row.event}
          phx-value-id={row.id}
          phx-value-project={row[:project_id]}
          class="w-full flex items-center gap-2.5 px-3 py-2 mx-1 rounded-md text-left hover:bg-zinc-200/60 dark:hover:bg-zinc-700/40"
        >
          <span :if={row[:dot]} class={["h-2.5 w-2.5 flex-none rounded-full", row.dot]} />
          <span class="truncate text-sm font-medium text-zinc-800 dark:text-zinc-100">
            {row.name}
          </span>
          <span class="ml-auto flex items-center gap-1.5 flex-none">
            <span :if={row[:count]} class="text-xs text-zinc-400 tabular-nums">{row.count}</span>
            <svg viewBox="0 0 20 20" fill="currentColor" class="w-4 h-4 text-zinc-400">
              <path
                fill-rule="evenodd"
                d="M7.21 14.77a.75.75 0 0 1 0-1.06L10.94 10 7.21 6.29a.75.75 0 1 1 1.06-1.06l4.25 4.24a.75.75 0 0 1 0 1.06l-4.25 4.24a.75.75 0 0 1-1.06 0Z"
                clip-rule="evenodd"
              />
            </svg>
          </span>
        </button>

        <div :if={@view.rows == []} class="px-3 py-2 mx-1 text-xs text-zinc-400 italic">
          {@view.empty}
        </div>

        <.link
          :if={@view.new_workspace_project}
          navigate={"/projects/#{@view.new_workspace_project}/new"}
          class="flex items-center gap-2 px-3 py-1.5 mx-1 text-xs text-zinc-400 hover:text-violet-500 dark:hover:text-violet-400"
        >
          + new workspace
        </.link>
      </div>
    </nav>
    """
  end

  # ── Level resolution ──

  # Projects level.
  defp resolve_view(tree, nil) do
    rows =
      Enum.map(tree, fn p ->
        wss = p.workspaces
        agents = Enum.flat_map(wss, & &1.agents)
        single = match?([_], wss)

        %{
          kind: :project,
          id: p.id,
          name: p.name,
          dot: aggregate_dot(agents),
          count: agent_count_label(agents),
          # single-workspace project → drill straight to its agents
          event: if(single, do: "sidebar_open_workspace", else: "sidebar_open_project"),
          project_id: if(single, do: p.id)
        }
        |> then(fn row -> if single, do: Map.put(row, :id, hd(wss).id), else: row end)
      end)

    %{
      back: false,
      title: "Projects",
      rows: rows,
      empty: "no projects yet",
      new_workspace_project: nil
    }
  end

  # Workspaces level (a project's workspaces).
  defp resolve_view(tree, {:project, project_id}) do
    project = find_project(tree, project_id)

    rows =
      for ws <- project_workspaces(project) do
        %{
          kind: :workspace,
          id: ws.id,
          project_id: project_id,
          name: ws.name,
          dot: aggregate_dot(ws.agents),
          count: agent_count_label(ws.agents),
          event: "sidebar_open_workspace"
        }
      end

    %{
      back: true,
      title: project_name(project),
      rows: rows,
      empty: "no workspaces",
      new_workspace_project: project_id
    }
  end

  # Agents level (a workspace's agents).
  defp resolve_view(tree, {:workspace, project_id, workspace_id}) do
    project = find_project(tree, project_id)
    ws = find_workspace(project, workspace_id)

    rows =
      for a <- workspace_agents(ws) do
        %{
          kind: :agent,
          id: a.id,
          name: a.name,
          status: a.status,
          active_tool: a.active_tool,
          path: "/projects/#{project_id}/workspaces/#{workspace_id}/agents/#{a.id}"
        }
      end

    %{
      back: true,
      title: workspace_name(ws),
      rows: rows,
      empty: "no agents",
      new_workspace_project: nil
    }
  end

  @doc """
  The parent focus for the back button, given the current focus and tree. A
  single-workspace project's agents zoom straight back to Projects (we skipped
  the workspace level going in).
  """
  def parent_focus(_tree, {:project, _}), do: nil

  def parent_focus(tree, {:workspace, project_id, _workspace_id}) do
    project = find_project(tree, project_id)
    if match?([_], project_workspaces(project)), do: nil, else: {:project, project_id}
  end

  def parent_focus(_tree, _), do: nil

  # ── Lookups + display helpers ──

  defp find_project(tree, id), do: Enum.find(tree, &(&1.id == id))
  defp find_workspace(nil, _), do: nil
  defp find_workspace(project, id), do: Enum.find(project.workspaces, &(&1.id == id))

  defp project_workspaces(nil), do: []
  defp project_workspaces(project), do: project.workspaces
  defp project_name(nil), do: "Project"
  defp project_name(project), do: project.name
  defp workspace_agents(nil), do: []
  defp workspace_agents(ws), do: ws.agents
  defp workspace_name(nil), do: "Workspace"
  defp workspace_name(ws), do: ws.name

  defp agent_count_label([]), do: nil
  defp agent_count_label(agents), do: "#{length(agents)}"

  # Aggregate dot for a group: loudest live state wins.
  defp aggregate_dot(agents) do
    statuses = Enum.map(agents, & &1.status)

    cond do
      Enum.any?(statuses, &(&1 in [:thinking, :compacting])) -> "bg-blue-500 animate-pulse"
      Enum.any?(statuses, &(&1 in [:rate_limited, :auth_expired, :crashed])) -> "bg-amber-500"
      Enum.any?(statuses, &(&1 == :idle)) -> "bg-emerald-500"
      true -> "bg-zinc-300 dark:bg-zinc-600"
    end
  end

  defp status_dot(:thinking), do: "bg-blue-500 animate-pulse"
  defp status_dot(:compacting), do: "bg-blue-400 animate-pulse"
  defp status_dot(:backoff), do: "bg-amber-400 animate-pulse"
  defp status_dot(:idle), do: "bg-emerald-500"
  defp status_dot(:rate_limited), do: "bg-amber-500"
  defp status_dot(:auth_expired), do: "bg-red-500"
  defp status_dot(:crashed), do: "bg-red-500"
  defp status_dot(:stopped), do: "bg-zinc-400"
  defp status_dot(_), do: "bg-zinc-400"
end
