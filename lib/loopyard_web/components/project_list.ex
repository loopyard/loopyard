defmodule LoopyardWeb.Components.ProjectList do
  @moduledoc """
  The ONE grouped project → workspace list. iOS-grouped-list visual language
  (section header + rows on a tinted rounded container), NOT cards. Rendered in
  exactly two places so there's one visual language, never two:

    * the root screen (`/`) — "Your projects", the full birdseye.
    * the mobile switcher sheet — tapping a project/workspace crumb loads THIS
      same list up, with the current workspace highlighted and a `row_click`
      that closes the sheet on selection.

  Data is `Loopyard.WorkspaceTree.global/1` (projects with `:workspaces`, each
  workspace with `:agents` and `:ports`).
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
    <div class="space-y-6">
      <section :for={project <- @projects}>
        <%!-- Group header: the project. Tappable to its overview; count on the right. --%>
        <.link
          navigate={"/projects/#{project.id}"}
          phx-click={@row_click}
          class="group flex items-baseline gap-2 px-1 pb-2"
        >
          <h2 class="text-lg font-semibold tracking-tight text-zinc-900 dark:text-zinc-50 truncate">
            {project.name}
          </h2>
          <span class="ml-auto flex-none text-xs text-zinc-400 dark:text-zinc-500">
            {length(project.workspaces)} {ws_word(length(project.workspaces))}
          </span>
        </.link>

        <%!-- Rows: workspaces on a tinted, rounded, hairline-divided container. --%>
        <div class="overflow-hidden rounded-xl bg-zinc-50 dark:bg-zinc-800/40 divide-y divide-zinc-200/70 dark:divide-zinc-700/50">
          <.link
            :for={ws <- project.workspaces}
            navigate={"/projects/#{project.id}/workspaces/#{ws.id}"}
            phx-click={@row_click}
            aria-current={ws.id == @current_workspace_id && "true"}
            class={[
              "flex items-center gap-3 px-4 min-h-[3.5rem] py-2.5 transition-colors",
              if(ws.id == @current_workspace_id,
                do: "bg-violet-100 dark:bg-violet-500/15",
                else: "hover:bg-zinc-100 dark:hover:bg-zinc-800/60 active:bg-zinc-200 dark:active:bg-zinc-700/50"
              )
            ]}
          >
            <%!-- aggregate_dot is nil for a no-agent workspace — fall back to a
                 neutral gray so every row has a visible status bubble. --%>
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
            class="px-4 py-3 text-sm text-zinc-400 dark:text-zinc-500 italic"
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
