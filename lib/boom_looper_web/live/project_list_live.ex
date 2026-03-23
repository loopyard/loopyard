defmodule BoomLooperWeb.ProjectListLive do
  use BoomLooperWeb, :live_view

  alias BoomLooper.ProjectRegistry
  alias BoomLooper.ChatAgent

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      ChatAgent.subscribe()
    end

    secret = Application.get_env(:boom_looper, :launch_secret, "")
    port = Application.get_env(:boom_looper, BoomLooperWeb.Endpoint)[:http][:port] || 4000
    launch_cmd = "open \"http://localhost:#{port}/launch/#{secret}?path=$(pwd)\""

    {:ok,
     socket
     |> assign(:projects, load_projects())
     |> assign(:launch_cmd, launch_cmd)}
  end

  @impl true
  def handle_event("add_project", %{"path" => path}, socket) do
    path = String.trim(path)

    case ProjectRegistry.add(path) do
      {:ok, project, workspace} ->
        {:noreply, push_navigate(socket, to: "/projects/#{project.id}/workspaces/#{workspace.id}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  end

  @impl true
  def handle_event("remove_project", %{"id" => id}, socket) do
    ProjectRegistry.remove_project(id)
    {:noreply, assign(socket, :projects, load_projects())}
  end

  @impl true
  def handle_info({event, _}, socket)
      when event in [:chat_agent_started, :chat_agent_stopped, :chat_agent_booting, :chat_agent_removed] do
    {:noreply, assign(socket, :projects, load_projects())}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp load_projects do
    agents = ChatAgent.list_agents()

    ProjectRegistry.list_projects()
    |> Enum.map(fn project ->
      workspaces = ProjectRegistry.list_workspaces(project.id)
      agent_count = Enum.count(agents, fn a ->
        Enum.any?(workspaces, fn w -> a[:bind_mount] == w.path || a[:working_dir] == w.path end)
      end)
      Map.merge(project, %{workspace_count: length(workspaces), agent_count: agent_count})
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-screen flex flex-col bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100">
      <header class="flex-none h-14 border-b border-zinc-200 dark:border-zinc-700/80 flex items-center px-4 md:px-5">
        <h1 class="text-lg font-semibold tracking-tight">Boom Looper</h1>
      </header>
      <div class="flex-1 overflow-y-auto">
        <div class="max-w-2xl mx-auto px-4 py-8">
          <p :if={@flash["error"]} class="mb-4 rounded-lg bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 px-4 py-3 text-sm text-red-700 dark:text-red-300">
            {@flash["error"]}
          </p>

          <%!-- Projects --%>
          <section class="mb-10">
            <h2 class="text-xl font-semibold mb-1">Projects</h2>
            <p class="text-sm text-zinc-500 dark:text-zinc-400 mb-4">Each project is a git repo with its own containers and agents.</p>

            <div class="space-y-2 mb-4">
              <.link :for={project <- @projects} navigate={"/projects/#{project.id}"}
                class="block w-full rounded-xl border border-zinc-200 dark:border-zinc-700 p-4 hover:border-violet-400 dark:hover:border-violet-500 hover:bg-zinc-50 dark:hover:bg-zinc-800/50 transition-colors group">
                <div class="flex items-center justify-between">
                  <div class="min-w-0">
                    <div class="flex items-center gap-2">
                      <span class="text-sm font-semibold truncate">{project.name}</span>
                      <span :if={project.workspace_count > 0} class="text-xs font-medium text-zinc-500 dark:text-zinc-400 bg-zinc-100 dark:bg-zinc-800 rounded-full px-2 py-0.5">
                        {project.workspace_count} workspace{if project.workspace_count != 1, do: "s"}
                      </span>
                      <span :if={project.agent_count > 0} class="text-xs font-medium text-violet-600 dark:text-violet-400 bg-violet-100 dark:bg-violet-900/30 rounded-full px-2 py-0.5">
                        {project.agent_count} agent{if project.agent_count != 1, do: "s"}
                      </span>
                    </div>
                    <p class="text-xs font-mono text-zinc-400 dark:text-zinc-500 mt-0.5 truncate">{shorten_path(project.path)}</p>
                  </div>
                  <button phx-click="remove_project" phx-value-id={project.id}
                    class="text-zinc-300 dark:text-zinc-600 hover:text-red-500 dark:hover:text-red-400 opacity-0 group-hover:opacity-100 transition-opacity flex-none ml-3"
                    title="Remove project">
                    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-4 h-4">
                      <path d="M5.28 4.22a.75.75 0 0 0-1.06 1.06L6.94 8l-2.72 2.72a.75.75 0 1 0 1.06 1.06L8 9.06l2.72 2.72a.75.75 0 1 0 1.06-1.06L9.06 8l2.72-2.72a.75.75 0 0 0-1.06-1.06L8 6.94 5.28 4.22Z" />
                    </svg>
                  </button>
                </div>
              </.link>

              <div :if={@projects == []} class="text-center py-8">
                <p class="text-sm text-zinc-400 dark:text-zinc-500">No projects yet. Add one below or use the launch command.</p>
              </div>
            </div>

            <form phx-submit="add_project" class="flex gap-2">
              <input type="text" name="path" placeholder="Enter project directory path..." autocomplete="off" autofocus
                class="flex-1 rounded-xl border border-zinc-300 dark:border-zinc-600 bg-white dark:bg-zinc-800 px-4 py-3 text-sm font-mono
                       text-zinc-600 dark:text-zinc-300 placeholder:text-zinc-400
                       focus:outline-none focus:ring-2 focus:ring-violet-500/20 focus:border-violet-400" />
              <button type="submit"
                class="rounded-xl border border-zinc-200 dark:border-zinc-700 px-5 py-3 text-sm font-medium text-zinc-600 dark:text-zinc-400
                       hover:bg-zinc-100 dark:hover:bg-zinc-800 transition-colors flex-none">
                Add
              </button>
            </form>
          </section>

          <%!-- Quick actions --%>
          <section class="mb-10">
            <h2 class="text-sm font-semibold text-zinc-500 dark:text-zinc-400 uppercase tracking-wider mb-3">Tools</h2>
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-2">
              <.link navigate="/remote"
                class="rounded-xl border border-zinc-200 dark:border-zinc-700 p-4 hover:border-violet-400 dark:hover:border-violet-500 hover:bg-zinc-50 dark:hover:bg-zinc-800/50 transition-colors">
                <div class="flex items-center gap-3">
                  <div class="w-8 h-8 rounded-lg bg-violet-100 dark:bg-violet-900/30 flex items-center justify-center flex-none">
                    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-4 h-4 text-violet-600 dark:text-violet-400">
                      <path d="M1 9.5A3.5 3.5 0 0 0 4.5 13H12a3 3 0 0 0 .917-5.857 2.503 2.503 0 0 0-3.198-3.019 3.5 3.5 0 0 0-6.628 2.171A3.5 3.5 0 0 0 1 9.5Z" />
                    </svg>
                  </div>
                  <div>
                    <p class="text-sm font-medium">Remote Access</p>
                    <p class="text-xs text-zinc-400 dark:text-zinc-500">Connect devices from anywhere</p>
                  </div>
                </div>
              </.link>

              <.link navigate="/system"
                class="rounded-xl border border-zinc-200 dark:border-zinc-700 p-4 hover:border-violet-400 dark:hover:border-violet-500 hover:bg-zinc-50 dark:hover:bg-zinc-800/50 transition-colors">
                <div class="flex items-center gap-3">
                  <div class="w-8 h-8 rounded-lg bg-zinc-100 dark:bg-zinc-800 flex items-center justify-center flex-none">
                    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-4 h-4 text-zinc-500 dark:text-zinc-400">
                      <path fill-rule="evenodd" d="M6.455 1.45A.5.5 0 0 1 6.952 1h2.096a.5.5 0 0 1 .497.45l.186 1.858a4.996 4.996 0 0 1 1.466.848l1.703-.769a.5.5 0 0 1 .639.206l1.047 1.814a.5.5 0 0 1-.142.656l-1.517 1.09a5.026 5.026 0 0 1 0 1.694l1.517 1.09a.5.5 0 0 1 .142.656l-1.047 1.814a.5.5 0 0 1-.639.206l-1.703-.769c-.433.36-.928.649-1.466.848l-.186 1.858a.5.5 0 0 1-.497.45H6.952a.5.5 0 0 1-.497-.45l-.186-1.858a4.993 4.993 0 0 1-1.466-.848l-1.703.769a.5.5 0 0 1-.639-.206L1.414 10.5a.5.5 0 0 1 .142-.656l1.517-1.09a5.026 5.026 0 0 1 0-1.694l-1.517-1.09a.5.5 0 0 1-.142-.656L2.46 3.5a.5.5 0 0 1 .639-.206l1.703.769c.433-.36.928-.649 1.466-.848l.186-1.858ZM8 10.5a2.5 2.5 0 1 0 0-5 2.5 2.5 0 0 0 0 5Z" clip-rule="evenodd" />
                    </svg>
                  </div>
                  <div>
                    <p class="text-sm font-medium">System</p>
                    <p class="text-xs text-zinc-400 dark:text-zinc-500">Debug state, reset containers</p>
                  </div>
                </div>
              </.link>
            </div>
          </section>

          <%!-- Launch command --%>
          <section>
            <h2 class="text-sm font-semibold text-zinc-500 dark:text-zinc-400 uppercase tracking-wider mb-3">Launch Command</h2>
            <div class="rounded-xl border border-zinc-200 dark:border-zinc-700 bg-zinc-50 dark:bg-zinc-800/50 p-4">
              <p class="text-xs text-zinc-500 dark:text-zinc-400 mb-2">Run from any project directory to add it to Boom Looper</p>
              <div class="flex items-center gap-2">
                <code class="flex-1 text-sm font-mono text-zinc-700 dark:text-zinc-300 bg-zinc-100 dark:bg-zinc-950 rounded-lg px-3 py-2.5 overflow-x-auto whitespace-nowrap">{@launch_cmd}</code>
                <button id="copy-launch" phx-hook="CopySource" data-source={@launch_cmd}
                  class="flex-none rounded-lg bg-violet-600 hover:bg-violet-500 text-white px-4 py-2.5 text-sm font-medium transition-colors">
                  Copy
                </button>
              </div>
            </div>
          </section>
        </div>
      </div>
    </div>
    """
  end

  defp shorten_path(path) do
    home = System.user_home!()
    String.replace_prefix(path, home, "~")
  end
end
