defmodule LoopyardWeb.Components.ProjectList do
  @moduledoc """
  The ONE grouped project → workspace list. Deliberately the SAME familiar UI in
  every place a project/workspace is picked, so the gesture is learned once:

    * `/workspaces` — the full list.
    * the mobile switcher sheet — the crumb opens this same list, current
      workspace highlighted, `row_click` closing the sheet on selection.
    * the desktop rail (`GlobalSidebar`) — the persistent left nav.

  Visual language: a large project name, its workspaces listed beneath with the
  status dot left-aligned to the name, a subtle gap between rows, and NO boxes —
  just a quiet highlight on the current/hovered row. Data is
  `Loopyard.WorkspaceTree.global/1` (projects with `:workspaces`, each with
  `:agents` and `:ports`).
  """
  use Phoenix.Component

  alias LoopyardWeb.Components.Birdseye

  @doc """
  Renders the grouped list.

    * `projects` — `WorkspaceTree.global` list.
    * `current_workspace_id` — highlight this workspace's row (switcher context).
    * `row_click` — optional `JS` to also run when a workspace row is tapped
      (e.g. `JS.hide(to: "#nav-switcher")` so the switcher closes on selection).
  """
  attr :projects, :list, required: true
  attr :current_workspace_id, :string, default: nil
  attr :row_click, :any, default: nil

  def project_groups(assigns) do
    ~H"""
    <div class="space-y-5">
      <section :for={project <- @projects}>
        <%!-- Project header: large name, count on the right. STICKY so it pins
             while its workspaces scroll beneath it — a solid (opaque) bg + a soft
             bottom shadow make rows read as sliding UNDER it, not merging. Works
             in every scroll context (rail, sheet, page). --%>
        <.link
          navigate={"/projects/#{project.id}"}
          phx-click={@row_click}
          class="group sticky top-0 z-10 flex items-baseline gap-2 bg-white dark:bg-zinc-900 pt-1 pb-1.5 shadow-[0_5px_6px_-6px_rgba(0,0,0,0.28)]"
        >
          <h2 class="text-xl font-semibold tracking-tight text-zinc-900 dark:text-zinc-50 truncate group-hover:text-violet-600 dark:group-hover:text-violet-400 transition-colors">
            {project.name}
          </h2>
          <span class="ml-auto flex-none text-xs text-zinc-400 dark:text-zinc-500">
            {length(project.workspaces)} {ws_word(length(project.workspaces))}
          </span>
        </.link>

        <%!-- Workspaces: NO boxes. The status dot left-aligns to the project name;
             a subtle gap between rows; just a quiet highlight on the current/hover
             row. --%>
        <div class="space-y-0.5 pt-1.5">
          <.link
            :for={ws <- project.workspaces}
            navigate={workspace_href(project.id, ws)}
            phx-click={@row_click}
            aria-current={ws.id == @current_workspace_id && "true"}
            class={[
              "flex items-center gap-2.5 -mx-2 px-2 py-2 rounded-lg transition-colors",
              if(ws.id == @current_workspace_id,
                do: "bg-violet-100 dark:bg-violet-500/15",
                else: "hover:bg-zinc-100 dark:hover:bg-zinc-800/60 active:bg-zinc-200 dark:active:bg-zinc-700/50"
              )
            ]}
          >
            <%!-- aggregate_dot is nil for a no-agent workspace — neutral gray
                 fallback so every row has a status bubble. Left-aligned with the
                 project name above. --%>
            <Birdseye.dot
              class={Birdseye.aggregate_dot(ws.agents) || "bg-zinc-300 dark:bg-zinc-600"}
              size={:md}
            />
            <div class="min-w-0 flex-1">
              <div class="flex items-center gap-2">
                <span class="font-medium text-zinc-900 dark:text-zinc-100 truncate">{ws.name}</span>
                <span
                  :for={p <- ws.ports}
                  class="flex-none font-mono text-xs text-emerald-600 dark:text-emerald-400"
                >
                  :{p.port}
                </span>
              </div>
              <div class="text-xs text-zinc-500 dark:text-zinc-400 truncate">{ws_summary(ws)}</div>
            </div>
          </.link>

          <div
            :if={project.workspaces == []}
            class="px-2 py-2 text-sm text-zinc-400 dark:text-zinc-500 italic"
          >
            no workspaces
          </div>
        </div>
      </section>

      <div :if={@projects == []} class="text-sm text-zinc-400 py-8 text-center">
        No projects yet.
      </div>
    </div>
    """
  end

  defp ws_word(1), do: "workspace"
  defp ws_word(_), do: "workspaces"

  # Link straight to an agent when the workspace has one — one navigation lands on
  # the chat, avoiding the workspace :index render-then-redirect flicker. Empty
  # workspace → its :index (which spawns an agent).
  defp workspace_href(project_id, %{agents: [agent | _]} = ws) when is_map(agent) do
    "/projects/#{project_id}/workspaces/#{ws.id}/agents/#{agent.id}"
  end

  defp workspace_href(project_id, ws), do: "/projects/#{project_id}/workspaces/#{ws.id}"

  # One compact line under the workspace name: who's here + what they're doing.
  defp ws_summary(%{agents: []}), do: "no agent yet"

  defp ws_summary(%{agents: [agent]}) do
    "#{agent.name} · #{status_word(agent[:status])}"
  end

  defp ws_summary(%{agents: agents}) do
    working = Enum.count(agents, &(&1.status == :thinking))
    base = "#{length(agents)} agents"
    if working > 0, do: "#{base} · #{working} working", else: base
  end

  defp status_word(:thinking), do: "working"
  defp status_word(:idle), do: "idle"
  defp status_word(status) when is_atom(status) and not is_nil(status), do: to_string(status)
  defp status_word(_), do: "idle"
end
