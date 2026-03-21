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
       |> assign(:branches, load_branches(project))}
    end
  end

  @impl true
  def handle_event("start_branch", %{"id" => branch_id}, socket) do
    branch = ProjectRegistry.get_branch(branch_id)
    if branch do
      BoomLooper.BranchSupervisor.start_branch(branch_id, branch.path)
      ProjectRegistry.update_branch_status(branch_id, :running)
    end
    {:noreply, assign(socket, :branches, load_branches(socket.assigns.project))}
  end

  @impl true
  def handle_event("stop_branch", %{"id" => branch_id}, socket) do
    BoomLooper.BranchSupervisor.stop_branch(branch_id)
    ProjectRegistry.update_branch_status(branch_id, :stopped)
    {:noreply, assign(socket, :branches, load_branches(socket.assigns.project))}
  end

  @impl true
  def handle_event("add_branch", %{"name" => name}, socket) do
    name = String.trim(name)

    if name != "" do
      case ProjectRegistry.add_branch(socket.assigns.project.id, name) do
        {:ok, branch} ->
          {:noreply, push_navigate(socket, to: "/p/#{socket.assigns.project.id}/b/#{branch.id}")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, reason)}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("remove_branch", %{"id" => id}, socket) do
    # Stop the branch supervisor first (cleans up containers)
    BoomLooper.BranchSupervisor.stop_branch(id)

    case ProjectRegistry.remove_branch(id) do
      :ok -> {:noreply, assign(socket, :branches, load_branches(socket.assigns.project))}
      {:error, reason} -> {:noreply, put_flash(socket, :error, reason)}
    end
  end

  @impl true
  def handle_info({event, _}, socket)
      when event in [:chat_agent_started, :chat_agent_stopped, :chat_agent_booting, :chat_agent_removed] do
    {:noreply, assign(socket, :branches, load_branches(socket.assigns.project))}
  end

  @impl true
  def handle_info({:services_updated, _path, _statuses}, socket) do
    {:noreply, assign(socket, :branches, load_branches(socket.assigns.project))}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp load_branches(project) do
    agents = ChatAgent.list_agents()

    ProjectRegistry.list_branches(project.id)
    |> Enum.map(fn branch ->
      agent_count = Enum.count(agents, fn a ->
        a[:bind_mount] == branch.path || a[:working_dir] == branch.path
      end)

      service_count = case BoomLooper.Workspace.ServiceManager.service_status(branch.path) do
        {:ok, statuses} ->
          statuses
          |> Enum.reject(&(Map.get(&1, :type) == :workspace))
          |> Enum.count(& &1.running)
        _ -> 0
      end

      branch
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
            <div :for={branch <- @branches}
              class="rounded-xl border border-zinc-200 dark:border-zinc-700 p-4 hover:border-violet-400 dark:hover:border-violet-500 hover:bg-zinc-50 dark:hover:bg-zinc-800/50 transition-colors group">
              <div class="flex items-center justify-between">
                <.link navigate={"/p/#{@project.id}/b/#{branch.id}"} class="flex items-center gap-2 min-w-0 flex-1">
                  <div class={"w-2 h-2 rounded-full flex-none #{if branch.status == :running, do: "bg-green-500", else: "bg-zinc-400"}"}></div>
                  <span class="text-sm font-medium truncate">{branch.name}</span>
                  <span :if={branch.is_main} class="text-[10px] uppercase tracking-wider text-zinc-400 dark:text-zinc-500">default</span>
                  <span :if={branch.agent_count > 0} class="text-xs font-medium text-violet-600 dark:text-violet-400 bg-violet-100 dark:bg-violet-900/30 rounded-full px-2 py-0.5">
                    {branch.agent_count} agent{if branch.agent_count != 1, do: "s"}
                  </span>
                  <span :if={branch.service_count > 0} class="text-xs font-medium text-green-600 dark:text-green-400 bg-green-100 dark:bg-green-900/30 rounded-full px-2 py-0.5">
                    {branch.service_count} service{if branch.service_count != 1, do: "s"}
                  </span>
                </.link>
                <div class="flex items-center gap-2 flex-none opacity-0 group-hover:opacity-100 transition-opacity">
                  <button :if={branch.status != :running} phx-click="start_branch" phx-value-id={branch.id}
                    class="text-xs font-medium text-green-600 dark:text-green-400 hover:text-green-500 transition-colors"
                    title="Start branch">
                    Start
                  </button>
                  <button :if={branch.status == :running} phx-click="stop_branch" phx-value-id={branch.id}
                    class="text-xs font-medium text-zinc-400 hover:text-red-500 dark:hover:text-red-400 transition-colors"
                    title="Stop branch">
                    Stop
                  </button>
                  <button :if={!branch.is_main} phx-click="remove_branch" phx-value-id={branch.id}
                    class="text-zinc-300 dark:text-zinc-600 hover:text-red-500 dark:hover:text-red-400 transition-colors"
                    title="Remove branch">
                    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-4 h-4">
                      <path d="M5.28 4.22a.75.75 0 0 0-1.06 1.06L6.94 8l-2.72 2.72a.75.75 0 1 0 1.06 1.06L8 9.06l2.72 2.72a.75.75 0 1 0 1.06-1.06L9.06 8l2.72-2.72a.75.75 0 0 0-1.06-1.06L8 6.94 5.28 4.22Z" />
                    </svg>
                  </button>
                </div>
              </div>
            </div>
          </div>

          <form :if={@project.is_git} phx-submit="add_branch" class="flex gap-2">
            <input type="text" name="name" placeholder="Branch name..." autocomplete="off"
              class="flex-1 rounded-xl border border-zinc-300 dark:border-zinc-600 bg-white dark:bg-zinc-800 px-4 py-3 text-sm font-mono
                     text-zinc-600 dark:text-zinc-300 placeholder:text-zinc-400
                     focus:outline-none focus:ring-2 focus:ring-violet-500/20 focus:border-violet-400" />
            <button type="submit"
              class="rounded-xl border border-zinc-200 dark:border-zinc-700 px-5 py-3 text-sm font-medium text-zinc-600 dark:text-zinc-400
                     hover:bg-zinc-100 dark:hover:bg-zinc-800 transition-colors flex-none">
              + Branch
            </button>
          </form>
        </div>
      </div>
    </div>
    """
  end
end
