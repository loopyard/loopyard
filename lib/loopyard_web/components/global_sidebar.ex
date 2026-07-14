defmodule LoopyardWeb.Components.GlobalSidebar do
  @moduledoc """
  The god-mode left rail (#55): every project → its workspaces, always
  expanded. No collapse state — projects are **sticky headers** and their
  workspaces scroll up under them (iOS grouped-list style), so you always see
  the whole map and scrolling just works. The project you're currently in
  keeps its header pinned as you scroll its workspaces.

  Fed by `Loopyard.WorkspaceTree.global/1`, kept live via the host LiveView.
  """
  use Phoenix.Component

  # Share the birdseye visual language with the home page: same status dots,
  # same aggregate logic, same openable port chip — so moving between the rail
  # and the home page feels like one system, and the same agent never shows two
  # different colors in two places.
  alias LoopyardWeb.Components.Birdseye

  attr :tree, :list, required: true
  attr :current_workspace_id, :string, default: nil
  attr :class, :string, default: nil

  def global_sidebar(assigns) do
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

      <div class="flex-1 overflow-y-auto">
        <div :if={@tree == []} class="px-3 py-2 text-sm text-zinc-400 italic">
          no projects yet
        </div>

        <%!-- Each project is a STICKY header; its workspaces flow below and
             scroll up under it. Always expanded — no collapse. --%>
        <section :for={project <- @tree}>
          <div class="sticky top-0 z-10 flex items-center px-3 py-1.5 bg-zinc-100 dark:bg-zinc-800 border-b border-zinc-200/80 dark:border-zinc-700/60">
            <span class="truncate text-sm font-bold uppercase tracking-wider text-zinc-500 dark:text-zinc-400">
              {project.name}
            </span>
          </div>

          <div class="py-1">
            <%!-- Two columns: [agent dot + workspace name] ......... [ :port ].
                 The port chip is a SIBLING of the row link (not nested inside
                 it) — nested <a> tags are invalid and get kicked out. --%>
            <div
              :for={ws <- project.workspaces}
              class={[
                "group flex items-center pr-2 mx-1 rounded-md",
                "hover:bg-zinc-200/60 dark:hover:bg-zinc-700/40",
                ws.id == @current_workspace_id && "bg-violet-100 dark:bg-violet-500/15"
              ]}
            >
              <.link
                navigate={workspace_link(project.id, ws)}
                class="flex-1 min-w-0 flex items-center gap-2.5 py-1.5 pl-3"
              >
                <Birdseye.dot class={Birdseye.aggregate_dot(ws.agents)} size={:sm} />
                <span class="truncate text-sm text-zinc-700 dark:text-zinc-200">{ws.name}</span>
              </.link>
              <Birdseye.port_chip :for={p <- ws.ports} port={p.port} url={p.url} />
            </div>

            <div
              :if={project.workspaces == []}
              class="py-1.5 pl-3 text-sm text-zinc-400 italic"
            >
              no workspaces
            </div>
          </div>
        </section>
      </div>
    </nav>
    """
  end

  # Link a workspace row straight to one of its agents when it has any — so the
  # click lands on the chat in ONE navigation. Going to the workspace :index
  # instead renders that page and THEN auto-redirects to an agent, and that
  # navigate-then-redirect is the visible flicker. Empty workspace → :index
  # (which auto-spawns the first agent).
  defp workspace_link(project_id, ws) do
    base = "/projects/#{project_id}/workspaces/#{ws.id}"

    case ws.agents do
      [agent | _] -> "#{base}/agents/#{agent.id}"
      _ -> base
    end
  end
end
