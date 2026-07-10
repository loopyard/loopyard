defmodule LoopyardWeb.Components.GlobalSidebar do
  @moduledoc """
  The god-mode left rail (#55): every project → workspace → agent in one live
  tree, each agent with a status dot + its current tool. Fed by
  `Loopyard.WorkspaceTree.global/0` and kept live by subscribing to
  `Loopyard.Events.Activity` in the host LiveView. Pure presentation — a
  self-contained component that can be dropped in or removed without touching
  anything else.
  """
  use Phoenix.Component

  attr :tree, :list, required: true
  attr :current_workspace_id, :string, default: nil
  attr :current_agent_id, :string, default: nil
  attr :class, :string, default: nil

  def global_sidebar(assigns) do
    ~H"""
    <nav class={["flex flex-col gap-3 p-2 text-sm overflow-y-auto", @class]} aria-label="Projects">
      <div :for={project <- @tree} class="flex flex-col">
        <div class="px-2 pt-1 pb-0.5 text-[11px] font-semibold uppercase tracking-wide text-zinc-500">
          {project.name}
        </div>

        <div :for={ws <- project.workspaces} class="flex flex-col">
          <div class={[
            "px-2 py-0.5 text-xs font-medium text-zinc-600 dark:text-zinc-300",
            ws.id == @current_workspace_id && "text-zinc-900 dark:text-zinc-100"
          ]}>
            {ws.name}
          </div>

          <.link
            :for={agent <- ws.agents}
            navigate={agent_path(project.id, ws.id, agent.id)}
            class={[
              "group flex items-center gap-2 rounded px-2 py-1 ml-1",
              "hover:bg-zinc-200/60 dark:hover:bg-zinc-700/40",
              agent.id == @current_agent_id && "bg-zinc-200 dark:bg-zinc-700/60"
            ]}
          >
            <span class={["h-2 w-2 flex-none rounded-full", status_dot(agent.status)]} />
            <span class="truncate text-zinc-700 dark:text-zinc-200">{agent.name}</span>
            <span
              :if={agent.active_tool}
              class="ml-auto truncate text-[10px] text-zinc-400 font-mono"
            >
              {agent.active_tool}
            </span>
          </.link>

          <div :if={ws.agents == []} class="px-2 py-0.5 ml-1 text-xs text-zinc-400 italic">
            no agents
          </div>
        </div>

        <.link
          navigate={"/projects/#{project.id}/new"}
          class="px-2 py-0.5 text-xs text-zinc-400 hover:text-violet-500 dark:hover:text-violet-400"
        >
          + workspace
        </.link>
      </div>

      <div :if={@tree == []} class="px-2 py-2 text-xs text-zinc-400 italic">
        no projects yet
      </div>
    </nav>
    """
  end

  defp agent_path(project_id, workspace_id, agent_id),
    do: "/projects/#{project_id}/workspaces/#{workspace_id}/agents/#{agent_id}"

  # Status → dot color. Loud on the states you'd want to notice across projects.
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
