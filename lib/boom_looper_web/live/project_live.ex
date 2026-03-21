defmodule BoomLooperWeb.ProjectLive do
  use BoomLooperWeb, :live_view

  alias BoomLooper.ProjectRegistry
  alias BoomLooper.ChatAgent

  @impl true
  def mount(%{"project_id" => project_id}, _session, socket) do
    project = ProjectRegistry.get_project(project_id)

    unless project do
      {:ok, push_navigate(socket, to: "/")}
    else
      if connected?(socket) do
        ChatAgent.subscribe()
        BoomLooper.Workspace.ServiceManager.subscribe()
      end

      {:ok,
       socket
       |> assign(:project, project)
       |> assign(:workspaces, load_workspaces(project))}
    end
  end

  @impl true
  def handle_event("start_workspace", %{"id" => workspace_id}, socket) do
    workspace = ProjectRegistry.get_workspace(workspace_id)
    if workspace do
      BoomLooper.WorkspaceSupervisor.start_workspace(workspace_id, workspace.path)
      ProjectRegistry.update_workspace_status(workspace_id, :running)
    end
    {:noreply, assign(socket, :workspaces, load_workspaces(socket.assigns.project))}
  end

  @impl true
  def handle_event("stop_workspace", %{"id" => workspace_id}, socket) do
    BoomLooper.WorkspaceSupervisor.stop_workspace(workspace_id)
    ProjectRegistry.update_workspace_status(workspace_id, :stopped)
    {:noreply, assign(socket, :workspaces, load_workspaces(socket.assigns.project))}
  end

  @impl true
  def handle_event("add_workspace", %{"name" => name}, socket) do
    name = String.trim(name)

    if name != "" do
      case ProjectRegistry.add_workspace(socket.assigns.project.id, name) do
        {:ok, workspace} ->
          {:noreply, push_navigate(socket, to: "/projects/#{socket.assigns.project.id}/workspaces/#{workspace.id}")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, reason)}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("remove_workspace", %{"id" => id}, socket) do
    # Stop the workspace supervisor first (cleans up containers)
    BoomLooper.WorkspaceSupervisor.stop_workspace(id)

    case ProjectRegistry.remove_workspace(id) do
      :ok -> {:noreply, assign(socket, :workspaces, load_workspaces(socket.assigns.project))}
      {:error, reason} -> {:noreply, put_flash(socket, :error, reason)}
    end
  end

  @impl true
  def handle_info({event, _}, socket)
      when event in [:chat_agent_started, :chat_agent_stopped, :chat_agent_booting, :chat_agent_removed] do
    {:noreply, assign(socket, :workspaces, load_workspaces(socket.assigns.project))}
  end

  @impl true
  def handle_info({:services_updated, _path, _statuses}, socket) do
    {:noreply, assign(socket, :workspaces, load_workspaces(socket.assigns.project))}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp load_workspaces(project) do
    agents = ChatAgent.list_agents()

    ProjectRegistry.list_workspaces(project.id)
    |> Enum.map(fn workspace ->
      agent_count = Enum.count(agents, fn a ->
        a[:bind_mount] == workspace.path || a[:working_dir] == workspace.path
      end)

      service_count = case BoomLooper.Workspace.ServiceManager.service_status(workspace.path) do
        {:ok, statuses} ->
          statuses
          |> Enum.reject(&(Map.get(&1, :type) == :workspace))
          |> Enum.count(& &1.running)
        _ -> 0
      end

      workspace
      |> Map.put(:agent_count, agent_count)
      |> Map.put(:service_count, service_count)
    end)
  end

  defp shorten_path(path) do
    home = System.user_home!()
    String.replace_prefix(path, home, "~")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-screen flex flex-col bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100">
      <header class="flex-none h-14 border-b border-zinc-200 dark:border-zinc-700/80 flex items-center px-4 md:px-5 gap-3">
        <.link navigate="/" class="text-lg font-semibold tracking-tight hover:text-violet-600 dark:hover:text-violet-400 transition-colors">Boom Looper</.link>
        <span class="text-zinc-300 dark:text-zinc-600">/</span>
        <span class="text-sm font-medium">{@project.name}</span>
      </header>
      <div class="flex-1 overflow-y-auto">
        <div class="max-w-2xl mx-auto px-4 py-8">
          <p :if={@flash["error"]} class="mb-4 rounded-lg bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 px-4 py-3 text-sm text-red-700 dark:text-red-300">
            {@flash["error"]}
          </p>

          <div class="flex items-center justify-between mb-6">
            <div>
              <h2 class="text-xl font-semibold">{@project.name}</h2>
              <p class="text-xs font-mono text-zinc-400 dark:text-zinc-500 mt-0.5">{shorten_path(@project.path)}</p>
            </div>
          </div>

          <div class="space-y-2 mb-8">
            <div :for={workspace <- @workspaces}
              class="rounded-xl border border-zinc-200 dark:border-zinc-700 p-4 hover:border-violet-400 dark:hover:border-violet-500 hover:bg-zinc-50 dark:hover:bg-zinc-800/50 transition-colors group">
              <div class="flex items-center justify-between">
                <.link navigate={"/projects/#{@project.id}/workspaces/#{workspace.id}"} class="flex items-center gap-2 min-w-0 flex-1">
                  <div class={"w-2 h-2 rounded-full flex-none #{if workspace.status == :running, do: "bg-green-500", else: "bg-zinc-400"}"}></div>
                  <span class="text-sm font-medium truncate">{workspace.name}</span>
                  <span :if={workspace.is_main} class="text-[10px] uppercase tracking-wider text-zinc-400 dark:text-zinc-500">default</span>
                  <span :if={workspace.agent_count > 0} class="text-xs font-medium text-violet-600 dark:text-violet-400 bg-violet-100 dark:bg-violet-900/30 rounded-full px-2 py-0.5">
                    {workspace.agent_count} agent{if workspace.agent_count != 1, do: "s"}
                  </span>
                  <span :if={workspace.service_count > 0} class="text-xs font-medium text-green-600 dark:text-green-400 bg-green-100 dark:bg-green-900/30 rounded-full px-2 py-0.5">
                    {workspace.service_count} service{if workspace.service_count != 1, do: "s"}
                  </span>
                </.link>
                <div class="flex items-center gap-2 flex-none opacity-0 group-hover:opacity-100 transition-opacity">
                  <button :if={workspace.status != :running} phx-click="start_workspace" phx-value-id={workspace.id}
                    class="text-xs font-medium text-green-600 dark:text-green-400 hover:text-green-500 transition-colors"
                    title="Start workspace">
                    Start
                  </button>
                  <button :if={workspace.status == :running} phx-click="stop_workspace" phx-value-id={workspace.id}
                    class="text-xs font-medium text-zinc-400 hover:text-red-500 dark:hover:text-red-400 transition-colors"
                    title="Stop workspace">
                    Stop
                  </button>
                  <button :if={!workspace.is_main} phx-click="remove_workspace" phx-value-id={workspace.id}
                    class="text-zinc-300 dark:text-zinc-600 hover:text-red-500 dark:hover:text-red-400 transition-colors"
                    title="Remove workspace">
                    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-4 h-4">
                      <path d="M5.28 4.22a.75.75 0 0 0-1.06 1.06L6.94 8l-2.72 2.72a.75.75 0 1 0 1.06 1.06L8 9.06l2.72 2.72a.75.75 0 1 0 1.06-1.06L9.06 8l2.72-2.72a.75.75 0 0 0-1.06-1.06L8 6.94 5.28 4.22Z" />
                    </svg>
                  </button>
                </div>
              </div>
            </div>
          </div>

          <form :if={@project.is_git} phx-submit="add_workspace" class="flex gap-2">
            <input type="text" name="name" placeholder="Workspace name..." autocomplete="off"
              class="flex-1 rounded-xl border border-zinc-300 dark:border-zinc-600 bg-white dark:bg-zinc-800 px-4 py-3 text-sm font-mono
                     text-zinc-600 dark:text-zinc-300 placeholder:text-zinc-400
                     focus:outline-none focus:ring-2 focus:ring-violet-500/20 focus:border-violet-400" />
            <button type="submit"
              class="rounded-xl border border-zinc-200 dark:border-zinc-700 px-5 py-3 text-sm font-medium text-zinc-600 dark:text-zinc-400
                     hover:bg-zinc-100 dark:hover:bg-zinc-800 transition-colors flex-none">
              + Workspace
            </button>
          </form>
        </div>
      </div>
    </div>
    """
  end
end
