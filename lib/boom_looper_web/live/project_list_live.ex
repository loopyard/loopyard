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
      <header class="flex-none h-14 border-b border-zinc-200 dark:border-zinc-700/80 flex items-center justify-between px-4 md:px-5">
        <h1 class="text-lg font-semibold tracking-tight">Boom Looper</h1>
        <div class="flex items-center gap-4">
          <.link navigate="/connect" class="text-xs text-zinc-400 dark:text-zinc-500 hover:text-zinc-600 dark:hover:text-zinc-300 transition-colors">Remote</.link>
          <.link navigate="/system" class="text-xs text-zinc-400 dark:text-zinc-500 hover:text-zinc-600 dark:hover:text-zinc-300 transition-colors">System</.link>
        </div>
      </header>
      <div class="flex-1 overflow-y-auto">
        <div class="max-w-xl mx-auto px-4 py-8">
          <p :if={@flash["error"]} class="mb-4 rounded-lg bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 px-4 py-3 text-sm text-red-700 dark:text-red-300">
            {@flash["error"]}
          </p>

          <%!-- Projects --%>
          <div class="space-y-2 mb-6">
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
                <button phx-click="remove_project" phx-value-id={project.id}
                  class="text-zinc-300 dark:text-zinc-600 hover:text-red-500 dark:hover:text-red-400 opacity-0 group-hover:opacity-100 transition-opacity flex-none ml-3"
                  title="Remove project">
                  <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-4 h-4">
                    <path d="M5.28 4.22a.75.75 0 0 0-1.06 1.06L6.94 8l-2.72 2.72a.75.75 0 1 0 1.06 1.06L8 9.06l2.72 2.72a.75.75 0 1 0 1.06-1.06L9.06 8l2.72-2.72a.75.75 0 0 0-1.06-1.06L8 6.94 5.28 4.22Z" />
                  </svg>
                </button>
              </div>
            </.link>
          </div>

          <%!-- Add project --%>
          <form phx-submit="add_project" class="flex gap-2 mb-3">
            <input type="text" name="path" placeholder="Project path..." autocomplete="off" autofocus
              class="flex-1 rounded-xl border border-zinc-300 dark:border-zinc-600 bg-white dark:bg-zinc-800 px-4 py-2.5 text-sm font-mono
                     text-zinc-600 dark:text-zinc-300 placeholder:text-zinc-400
                     focus:outline-none focus:ring-2 focus:ring-violet-500/20 focus:border-violet-400" />
            <button type="submit"
              class="rounded-xl bg-violet-600 hover:bg-violet-700 px-4 py-2.5 text-sm font-medium text-white transition-colors flex-none">
              Launch
            </button>
          </form>

          <div class="flex items-center gap-2 text-xs text-zinc-400 dark:text-zinc-500">
            <span>or from terminal:</span>
            <code class="font-mono bg-zinc-100 dark:bg-zinc-800 rounded px-1.5 py-0.5 select-all truncate max-w-xs">{@launch_cmd}</code>
            <button id="copy-launch" phx-hook="CopySource" data-source={@launch_cmd}
              class="text-violet-500 hover:text-violet-400 font-medium flex-none">copy</button>
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
