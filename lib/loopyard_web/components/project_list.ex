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
  # Compact tightens fonts + spacing for the narrow desktop rail; the /workspaces
  # page and the mobile sheet use the roomier default.
  attr :compact, :boolean, default: false

  def project_groups(assigns) do
    assigns =
      assign(assigns,
        name_class: if(assigns.compact, do: "text-base", else: "text-xl"),
        ws_name_class: if(assigns.compact, do: "text-sm", else: "text-base"),
        outer_gap: if(assigns.compact, do: "space-y-6", else: "space-y-9")
      )

    ~H"""
    <div class={@outer_gap}>
      <section :for={project <- @projects}>
        <%!-- Project header: large name (link) + a quiet "new workspace" + on the
             right. The workspace COUNT is gone — most projects have one, so the
             number was just noise; the + is a useful action instead. STICKY so it
             pins while its workspaces scroll beneath it; opaque bg covers rows
             sliding under; shadow only when actually stuck. --%>
        <div
          data-sticky-header
          class="sticky top-0 z-10 flex items-center gap-1 bg-white dark:bg-zinc-900 pt-1 pb-1 transition-shadow data-[stuck]:shadow-[0_5px_6px_-6px_rgba(0,0,0,0.28)]"
        >
          <.link navigate={"/projects/#{project.id}"} phx-click={@row_click} class="group min-w-0 flex-1">
            <h2 class={[
              @name_class,
              "font-semibold tracking-tight text-zinc-900 dark:text-zinc-50 truncate group-hover:text-violet-600 dark:group-hover:text-violet-400 transition-colors"
            ]}>
              {project.name}
            </h2>
          </.link>
          <.link
            navigate={"/projects/#{project.id}/new"}
            phx-click={@row_click}
            aria-label={"New workspace in #{project.name}"}
            title="New workspace"
            class="focus-ring flex-none inline-flex items-center justify-center w-7 h-7 -my-0.5 rounded-md text-zinc-400 hover:text-violet-600 dark:hover:text-violet-400 hover:bg-violet-50 dark:hover:bg-violet-500/10 transition-colors"
          >
            <svg viewBox="0 0 16 16" fill="currentColor" class="w-4 h-4" aria-hidden="true">
              <path d="M8.75 3.75a.75.75 0 0 0-1.5 0v3.5h-3.5a.75.75 0 0 0 0 1.5h3.5v3.5a.75.75 0 0 0 1.5 0v-3.5h3.5a.75.75 0 0 0 0-1.5h-3.5v-3.5Z" />
            </svg>
          </.link>
        </div>

        <%!-- Workspaces: NO boxes. The status dot left-aligns to the project name;
             a subtle gap between rows; just a quiet highlight on the current/hover
             row. --%>
        <div class="space-y-0.5 pt-0.5">
          <.link
            :for={ws <- project.workspaces}
            navigate={workspace_href(project.id, ws)}
            phx-click={@row_click}
            aria-current={ws.id == @current_workspace_id && "true"}
            class={[
              "group/ws flex items-center gap-2.5 -mx-2 px-2 py-2 rounded-lg transition-colors",
              # No hover box. The current workspace (switcher/rail only — never on
              # /workspaces) gets a quiet violet tint; hover is a name-color cue.
              ws.id == @current_workspace_id && "bg-violet-100 dark:bg-violet-500/15"
            ]}
          >
            <%!-- ONE clean line, mirroring the Agents/Services/Files bar: dot +
                 name on the left; the right cluster carries the public port and a
                 concise agent-status word. aggregate_dot is nil for a no-agent
                 workspace → neutral gray so every row still has a status bubble. --%>
            <Birdseye.dot
              class={Birdseye.aggregate_dot(ws.agents) || "bg-zinc-300 dark:bg-zinc-600"}
              size={:md}
            />
            <span class={[
              @ws_name_class,
              "min-w-0 flex-1 truncate font-medium text-zinc-900 dark:text-zinc-100 group-hover/ws:text-violet-600 dark:group-hover/ws:text-violet-400 transition-colors"
            ]}>{ws.name}</span>
            <span
              :for={p <- ws.ports}
              class="flex-none font-mono text-xs text-emerald-600 dark:text-emerald-400"
            >
              :{p.port}
            </span>
            <span class="flex-none text-xs text-zinc-500 dark:text-zinc-400">{ws_status(ws)}</span>
          </.link>

          <div
            :if={project.workspaces == []}
            class="px-2 py-2 text-sm text-zinc-500 dark:text-zinc-400 italic"
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

  # Link straight to an agent when the workspace has one — one navigation lands on
  # the chat, avoiding the workspace :index render-then-redirect flicker. Empty
  # workspace → its :index (which spawns an agent).
  defp workspace_href(project_id, %{agents: [agent | _]} = ws) when is_map(agent) do
    "/projects/#{project_id}/workspaces/#{ws.id}/agents/#{agent.id}"
  end

  defp workspace_href(project_id, ws), do: "/projects/#{project_id}/workspaces/#{ws.id}"

  # Right-aligned agent-status word for a workspace row. The dot already carries
  # the color; this is the concise word (idle / crashed / working). A single
  # agent shows its state; multiple show the count; none shows "no agent".
  defp ws_status(%{agents: []}), do: "no agent"
  defp ws_status(%{agents: [agent]}), do: status_word(agent[:status])

  defp ws_status(%{agents: agents}) do
    working = Enum.count(agents, &(&1[:status] == :thinking))
    base = "#{length(agents)} agents"
    if working > 0, do: "#{base} · #{working} working", else: base
  end

  defp status_word(:thinking), do: "working"
  defp status_word(:idle), do: "idle"
  defp status_word(status) when is_atom(status) and not is_nil(status), do: to_string(status)
  defp status_word(_), do: "idle"
end
