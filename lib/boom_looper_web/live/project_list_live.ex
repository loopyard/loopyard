defmodule BoomLooperWeb.ProjectListLive do
  use BoomLooperWeb, :live_view
  use BoomLooperWeb.IExAware

  alias BoomLooper.ProjectRegistry
  alias BoomLooper.ChatAgent

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      ChatAgent.subscribe()
    end

    socket = if connected?(socket), do: subscribe_iex(socket), else: assign(socket, :iex_session, %{level: nil})

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

    if path == "" do
      {:noreply, put_flash(socket, :error, "Enter a project path")}
    else

    case ProjectRegistry.add(path) do
      {:ok, project, workspace} ->
        {:noreply, push_navigate(socket, to: "/projects/#{project.id}/workspaces/#{workspace.id}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, reason)}
    end
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
    has_projects = assigns.projects != []
    assigns = assign(assigns, :has_projects, has_projects)

    ~H"""
    <div class="h-screen flex flex-col bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100">
      <.header breadcrumbs={[{"Boom Looper", nil}]} iex_session={@iex_session} />
      <div class="flex-1 overflow-y-auto">
        <div class="max-w-xl mx-auto px-4 py-8">
          <p :if={@flash["error"]} class="mb-4 rounded-lg bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 px-4 py-3 text-sm text-red-700 dark:text-red-300">
            {@flash["error"]}
          </p>

          <%!-- Empty state --%>
          <div :if={!@has_projects} class="mb-8">
            <h2 class="text-xl font-semibold mb-2">Add a project to get started</h2>
            <p class="text-sm text-zinc-500 dark:text-zinc-400 leading-relaxed">
              Point Boom Looper at a project directory. It'll spin up a Docker environment
              and launch an AI agent to set everything up. Paste a path below or use the terminal command.
            </p>
          </div>

          <%!-- Existing projects --%>
          <div :if={@has_projects} class="space-y-2 mb-6">
            <.link :for={project <- @projects} navigate={"/projects/#{project.id}"}
              class="block w-full rounded-xl border border-zinc-200 dark:border-zinc-700 p-4 hover:border-violet-400 dark:hover:border-violet-500 hover:bg-zinc-50 dark:hover:bg-zinc-800/50 transition-colors group">
              <div class="flex items-center justify-between">
                <div class="min-w-0">
                  <div class="flex items-center gap-2">
                    <span class="text-sm font-semibold truncate">{project.name}</span>
                    <span :if={project.agent_count > 0} class="text-xs font-medium text-violet-600 dark:text-violet-400 bg-violet-100 dark:bg-violet-900/30 rounded-full px-2 py-0.5">
                      {project.agent_count} agent{if project.agent_count != 1, do: "s"}
                    </span>
                  </div>
                  <p class="text-xs font-mono text-zinc-400 dark:text-zinc-500 mt-0.5 truncate">{shorten_path(project.path)}</p>
                </div>
                <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-3.5 h-3.5 text-zinc-300 dark:text-zinc-600 group-hover:text-zinc-500 dark:group-hover:text-zinc-400 transition-colors flex-none">
                  <path fill-rule="evenodd" d="M6.22 4.22a.75.75 0 0 1 1.06 0l3.25 3.25a.75.75 0 0 1 0 1.06l-3.25 3.25a.75.75 0 0 1-1.06-1.06L8.94 8 6.22 5.28a.75.75 0 0 1 0-1.06Z" clip-rule="evenodd" />
                </svg>
              </div>
            </.link>
          </div>

          <%!-- Add project --%>
          <div :if={@has_projects} class="mb-3">
            <h2 class="text-lg font-semibold">Add a project</h2>
          </div>

          <div class="space-y-3">
            <%!-- Option: Terminal command --%>
            <div class="rounded-xl border border-zinc-200 dark:border-zinc-700 bg-zinc-50 dark:bg-zinc-800/50 p-5 flex flex-col">
              <h3 class="text-sm font-semibold mb-1">From terminal</h3>
              <p class="text-xs text-zinc-500 dark:text-zinc-400 mb-3">
                <code class="text-zinc-700 dark:text-zinc-300">cd</code> into your project and run this command.
              </p>
              <div class="flex items-center gap-2 mt-auto">
                <div class="flex-1 bg-zinc-900 dark:bg-zinc-950 border border-zinc-200 dark:border-zinc-700 rounded-lg px-3 py-2 font-mono text-xs text-zinc-300 overflow-x-auto whitespace-nowrap select-all">
                  <span class="text-zinc-500 select-none">$ </span>{@launch_cmd}
                </div>
                <button id="copy-launch" phx-hook="CopySource" data-source={@launch_cmd}
                  class="flex-none rounded-lg bg-zinc-900 dark:bg-zinc-200 hover:bg-zinc-800 dark:hover:bg-white px-4 py-2 text-sm font-semibold text-white dark:text-zinc-900 transition-colors">
                  Copy
                </button>
              </div>
            </div>

            <%!-- Option: Paste path --%>
            <div class="rounded-xl border border-zinc-200 dark:border-zinc-700 bg-zinc-50 dark:bg-zinc-800/50 p-5 flex flex-col">
              <h3 class="text-sm font-semibold mb-1">Paste a path</h3>
              <p class="text-xs text-zinc-500 dark:text-zinc-400 mb-3">
                Full path to a project directory on this machine.
              </p>
              <form phx-submit="add_project" class="flex items-center gap-2 mt-auto">
                <input type="text" name="path" placeholder="/Users/you/projects/my-app" autocomplete="off"
                  class="flex-1 rounded-lg border border-zinc-300 dark:border-zinc-600 bg-white dark:bg-zinc-900 px-3 py-2 text-sm font-mono
                         text-zinc-900 dark:text-zinc-300 placeholder:text-zinc-400 dark:placeholder:text-zinc-600
                         focus:outline-none focus:ring-1 focus:ring-violet-500/20 focus:border-violet-400" />
                <button type="submit"
                  class="rounded-lg bg-zinc-900 dark:bg-zinc-200 hover:bg-zinc-800 dark:hover:bg-white px-4 py-2 text-sm font-semibold text-white dark:text-zinc-900 transition-colors flex-none">
                  Launch
                </button>
              </form>
            </div>
          </div>
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
