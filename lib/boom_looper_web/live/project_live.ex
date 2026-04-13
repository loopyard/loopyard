defmodule BoomLooperWeb.ProjectLive do
  use BoomLooperWeb, :live_view

  alias BoomLooper.ProjectRegistry
  alias BoomLooper.ChatAgent
  use BoomLooperWeb.IExAware

  @impl true
  def mount(%{"project_id" => project_id}, _session, socket) do
    project = ProjectRegistry.get_project(project_id)

    unless project do
      {:ok, push_navigate(socket, to: "/")}
    else
      if connected?(socket) do
        ChatAgent.subscribe()
        BoomLooper.Workspace.ServiceManager.subscribe()
        # Service/volume counts touch the filesystem and Docker — never
        # block mount on them. Render immediately with zeros, then fill
        # in via :fetch_service_counts.
        send(self(), :fetch_service_counts)
      end

      socket = if connected?(socket), do: subscribe_iex(socket), else: assign(socket, :iex_session, %{level: nil})

      {:ok,
       socket
       |> assign(:project, project)
       |> assign(:workspaces, load_workspaces(project, [:agents]))
       |> assign(:confirming_remove, false)
       |> assign(:editing_name, false)
       |> assign(:removing, false)}
    end
  end

  @impl true
  def handle_async(:remove_project, {:ok, _}, socket) do
    {:noreply, push_navigate(socket, to: "/")}
  end

  def handle_async(:remove_project, {:exit, _reason}, socket) do
    # Cleanup failed but the project is probably gone from ETS anyway
    {:noreply, push_navigate(socket, to: "/")}
  end

  @impl true
  def handle_event("start_workspace", %{"id" => workspace_id}, socket) do
    workspace = ProjectRegistry.get_workspace(workspace_id)
    if workspace do
      # workspace.path is normalized by ProjectRegistry for all workspace types
      BoomLooper.WorkspaceSupervisor.start_workspace(workspace_id, workspace.path)
      ProjectRegistry.update_workspace_status(workspace_id, :running)
    end
    {:noreply, assign(socket, :workspaces, load_workspaces(socket.assigns.project, [:agents, :services, :volumes]))}
  end

  @impl true
  def handle_event("stop_workspace", %{"id" => workspace_id}, socket) do
    BoomLooper.WorkspaceSupervisor.stop_workspace(workspace_id)
    ProjectRegistry.update_workspace_status(workspace_id, :stopped)
    {:noreply, assign(socket, :workspaces, load_workspaces(socket.assigns.project, [:agents, :services, :volumes]))}
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
  def handle_event("start_rename", _params, socket) do
    {:noreply, assign(socket, :editing_name, true)}
  end

  @impl true
  def handle_event("cancel_rename", _params, socket) do
    {:noreply, assign(socket, :editing_name, false)}
  end

  @impl true
  def handle_event("rename_project", %{"name" => name}, socket) do
    case ProjectRegistry.rename_project(socket.assigns.project.id, name) do
      {:ok, project} ->
        {:noreply,
         socket
         |> assign(:project, project)
         |> assign(:editing_name, false)}

      {:error, :empty_name} ->
        {:noreply, put_flash(socket, :error, "Project name can't be empty")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Project not found")}
    end
  end

  @impl true
  def handle_event("confirm_remove", _params, socket) do
    {:noreply, assign(socket, :confirming_remove, true)}
  end

  @impl true
  def handle_event("cancel_remove", _params, socket) do
    {:noreply, assign(socket, :confirming_remove, false)}
  end

  @impl true
  def handle_event("remove_project", _params, socket) do
    # Show "removing" immediately — the actual cleanup (compose down,
    # volume deletion) can take 10+ seconds. Without this, the button
    # appears to do nothing and users click it repeatedly.
    project_id = socket.assigns.project.id

    socket =
      socket
      |> assign(:removing, true)
      |> start_async(:remove_project, fn ->
        ProjectRegistry.remove_project(project_id)
      end)

    {:noreply, socket}
  end

  @impl true
  def handle_event("remove_workspace", %{"id" => id}, socket) do
    BoomLooper.WorkspaceSupervisor.stop_workspace(id)

    case ProjectRegistry.remove_workspace(id) do
      :ok -> {:noreply, assign(socket, :workspaces, load_workspaces(socket.assigns.project, [:agents, :services, :volumes]))}
      {:error, reason} -> {:noreply, put_flash(socket, :error, reason)}
    end
  end

  @impl true
  def handle_info({event, _}, socket)
      when event in [:chat_agent_started, :chat_agent_stopped, :chat_agent_booting, :chat_agent_removed] do
    {:noreply, assign(socket, :workspaces, load_workspaces(socket.assigns.project, [:agents, :services, :volumes]))}
  end

  @impl true
  def handle_info({:services_updated, _path, _statuses}, socket) do
    {:noreply, assign(socket, :workspaces, load_workspaces(socket.assigns.project, [:agents, :services, :volumes]))}
  end

  @impl true
  def handle_info(:fetch_service_counts, socket) do
    {:noreply, assign(socket, :workspaces, load_workspaces(socket.assigns.project, [:agents, :services, :volumes]))}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  # Caller asks for the slices it wants by listing them. The default mount
  # asks only for :agents (cheap, in-memory) so the page paints instantly;
  # async handlers come back and ask for :services and :volumes once Docker
  # is willing to talk.
  defp load_workspaces(project, sections) do
    ctx = %{agents: if(:agents in sections, do: ChatAgent.list_agents(), else: [])}

    ProjectRegistry.list_workspaces(project.id)
    |> Enum.map(fn workspace ->
      Enum.reduce([:agents, :services, :volumes], workspace, fn section, ws ->
        Map.merge(ws, load_section(section, sections, workspace, ctx))
      end)
    end)
  end

  defp load_section(:agents, sections, workspace, ctx) do
    if :agents in sections do
      count = Enum.count(ctx.agents, fn a ->
        a[:bind_mount] == workspace.path || a[:working_dir] == workspace.path || a[:workspace_id] == workspace.id
      end)
      %{agent_count: count}
    else
      %{agent_count: 0}
    end
  end

  defp load_section(:services, sections, workspace, _ctx) do
    if :services in sections do
      try do
        # ServiceStatus reads from docker-compose.yml — gives us all defined
        # services plus their current running state. Show total (so empty
        # workspaces don't look configurationless) and running side by side.
        statuses = BoomLooper.Docker.Observer.services_for(workspace.id)
        %{service_count: length(statuses), services_running: Enum.count(statuses, & &1.status == :running)}
      catch
        :exit, _ -> %{service_count: 0, services_running: 0}
      end
    else
      %{service_count: 0, services_running: 0}
    end
  end

  defp load_section(:volumes, sections, workspace, _ctx) do
    if :volumes in sections do
      count = case BoomLooper.VolumeManager.list_workspace_volumes(workspace.id) do
        {:ok, vols} -> length(vols)
        _ -> 0
      end
      %{volume_count: count}
    else
      %{volume_count: 0}
    end
  end


  defp removal_details(project) do
    # For volume-based projects, use the workspace dir
    ws_ids = ProjectRegistry.list_workspaces(project.id) |> Enum.map(& &1.id)
    project_dir = project[:path] || (ws_ids != [] && BoomLooper.Workspace.compose_dir(hd(ws_ids))) || "unknown"
    boomlooper_dir = Path.join(project_dir, ".boomlooper")
    workspace_dir = Path.join(boomlooper_dir, "workspace")

    files = if File.dir?(workspace_dir) do
      case File.ls(workspace_dir) do
        {:ok, entries} -> Enum.map(entries, &Path.join(".boomlooper/workspace", &1))
        _ -> []
      end
    else
      []
    end

    config_exists = File.exists?(Path.join(boomlooper_dir, "repo/workspace.json"))

    containers = ProjectRegistry.list_workspaces(project.id)
    |> Enum.flat_map(fn ws ->
      # ws.path is normalized by ProjectRegistry for all workspace types
      prefix = BoomLooper.Compose.project_name(ws.id)
      case BoomLooper.Compose.ps(ws.path, ws.id) do
        {:ok, services} -> Enum.map(services, fn s -> "#{prefix}-#{s.name}-1" end)
        _ -> []
      end
    end)

    %{
      boomlooper_dir: shorten_path(boomlooper_dir),
      generated_files: files,
      config_exists: config_exists,
      containers: containers
    }
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_shell breadcrumbs={[{"Boom Looper", "/"}, {@project.name, nil}]} iex_session={@iex_session} max_width={:md} flash={@flash}>
          <%= if @removing do %>
            <div class="text-center py-16">
              <div class="inline-block w-6 h-6 border-2 border-zinc-300 dark:border-zinc-600 border-t-violet-500 rounded-full animate-spin mb-4"></div>
              <h2 class="text-lg font-semibold text-zinc-600 dark:text-zinc-300">Removing {@project.name}...</h2>
              <p class="text-sm text-zinc-400 dark:text-zinc-500 mt-1">Stopping containers and cleaning up volumes</p>
            </div>
          <% else %>
          <%= if @confirming_remove do %>
            <.remove_confirmation project={@project} details={removal_details(@project)} />
          <% else %>
            <div class="flex items-center justify-between mb-6 gap-4">
              <div class="min-w-0 flex-1">
                <%= if @editing_name do %>
                  <form phx-submit="rename_project" phx-click-away="cancel_rename" class="flex items-center gap-2">
                    <input type="text" name="name" value={@project.name} autocomplete="off" autofocus
                      phx-keydown="cancel_rename" phx-key="Escape"
                      class="text-xl font-semibold bg-transparent border-b-2 border-violet-400 focus:outline-none focus:border-violet-500 px-0 py-0.5 min-w-0 flex-1
                             text-zinc-900 dark:text-zinc-100" />
                    <button type="submit" class="text-xs font-medium text-violet-600 dark:text-violet-400 hover:text-violet-500 transition-colors flex-none">Save</button>
                    <button type="button" phx-click="cancel_rename" class="text-xs font-medium text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-300 transition-colors flex-none">Cancel</button>
                  </form>
                <% else %>
                  <button phx-click="start_rename"
                    class="group flex items-center gap-2 text-left hover:text-violet-600 dark:hover:text-violet-400 transition-colors"
                    title="Rename project">
                    <h2 class="text-xl font-semibold truncate">{@project.name}</h2>
                    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor"
                      class="w-3.5 h-3.5 text-zinc-300 dark:text-zinc-600 opacity-0 group-hover:opacity-100 transition-opacity flex-none">
                      <path d="M2.695 14.762l-1.262 3.155a.5.5 0 00.65.65l3.155-1.262a4 4 0 001.343-.886L17.5 5.501a2.121 2.121 0 00-3-3L3.58 13.419a4 4 0 00-.885 1.343z" />
                    </svg>
                  </button>
                <% end %>
                <p class="text-xs font-mono text-zinc-400 dark:text-zinc-500 mt-0.5 truncate">{project_location(@project)}</p>
              </div>
              <button phx-click="confirm_remove"
                class="text-xs font-medium text-zinc-400 dark:text-zinc-500 hover:text-red-500 dark:hover:text-red-400 transition-colors flex-none">
                Remove project
              </button>
            </div>

            <div class="space-y-2 mb-8">
              <.link :for={workspace <- @workspaces}
                navigate={"/projects/#{@project.id}/workspaces/#{workspace.id}"}
                class={[
                  "block rounded-xl border p-4 transition-colors",
                  if(workspace.status == :running,
                    do: "border-green-300 dark:border-green-800 bg-green-50/50 dark:bg-green-950/20 hover:border-green-400",
                    else: "border-zinc-200 dark:border-zinc-700 hover:border-violet-400 dark:hover:border-violet-500 hover:bg-zinc-50 dark:hover:bg-zinc-800/50")
                ]}>
                <div class="flex items-center gap-3">
                  <div class={"w-2.5 h-2.5 rounded-full flex-none #{if workspace.status == :running, do: "bg-green-500", else: "bg-zinc-400"}"}></div>
                  <div class="min-w-0 flex-1">
                    <div class="flex items-center gap-2">
                      <span class="text-sm font-medium text-zinc-900 dark:text-zinc-100 truncate">{workspace.name}</span>
                      <span :if={workspace[:is_main]} class="text-[10px] uppercase tracking-wider text-zinc-400 dark:text-zinc-500 flex-none">default</span>
                    </div>
                    <p :if={workspace.status == :running} class="text-xs text-zinc-500 dark:text-zinc-400 mt-0.5">
                      {workspace.agent_count} agent{if workspace.agent_count != 1, do: "s"} · {workspace.services_running} service{if workspace.services_running != 1, do: "s"} running
                    </p>
                    <p :if={workspace.status != :running} class="text-xs text-zinc-400 dark:text-zinc-500 mt-0.5">
                      Stopped
                    </p>
                  </div>
                  <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-4 h-4 text-zinc-300 dark:text-zinc-600 flex-none">
                    <path fill-rule="evenodd" d="M6.22 4.22a.75.75 0 0 1 1.06 0l3.25 3.25a.75.75 0 0 1 0 1.06l-3.25 3.25a.75.75 0 0 1-1.06-1.06L8.94 8 6.22 5.28a.75.75 0 0 1 0-1.06Z" clip-rule="evenodd" />
                  </svg>
                </div>
              </.link>
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
          <% end %>
          <% end %>
    </.page_shell>
    """
  end

  defp remove_confirmation(assigns) do
    ~H"""
    <div class="space-y-6">
      <div>
        <h2 class="text-xl font-semibold text-red-600 dark:text-red-400">Remove {@project.name}</h2>
        <p class="text-sm text-zinc-500 dark:text-zinc-400 mt-1">This will permanently remove the project from Boom Looper. Your source code is not affected.</p>
      </div>

      <div class="rounded-lg border border-zinc-200 dark:border-zinc-700 divide-y divide-zinc-200 dark:divide-zinc-700">
        <div class="px-4 py-3">
          <div class="text-xs font-semibold uppercase tracking-wider text-zinc-400 dark:text-zinc-500 mb-2">Directory to delete</div>
          <p class="text-sm font-mono text-zinc-600 dark:text-zinc-400">{@details.boomlooper_dir}/</p>
          <ul :if={@details.generated_files != []} class="mt-1.5 space-y-0.5">
            <li :for={file <- @details.generated_files} class="text-xs font-mono text-zinc-400 dark:text-zinc-500 pl-4">{file}</li>
          </ul>
          <p :if={@details.config_exists} class="text-xs text-amber-600 dark:text-amber-400 mt-1.5">Includes workspace.json config (workspace settings, Dockerfile, services)</p>
        </div>

        <div class="px-4 py-3">
          <div class="text-xs font-semibold uppercase tracking-wider text-zinc-400 dark:text-zinc-500 mb-2">Docker containers to stop</div>
          <%= if @details.containers != [] do %>
            <ul class="space-y-0.5">
              <li :for={container <- @details.containers} class="text-sm font-mono text-zinc-600 dark:text-zinc-400">{container}</li>
            </ul>
          <% else %>
            <p class="text-sm text-zinc-400 dark:text-zinc-500">No running containers</p>
          <% end %>
        </div>
      </div>

      <div class="flex items-center gap-3">
        <button phx-click="remove_project"
          class="rounded-lg bg-red-600 hover:bg-red-700 text-white text-sm font-medium px-4 py-2 transition-colors">
          Remove project
        </button>
        <button phx-click="cancel_remove"
          class="text-sm font-medium text-zinc-500 dark:text-zinc-400 hover:text-zinc-700 dark:hover:text-zinc-200 transition-colors">
          Cancel
        </button>
      </div>
    </div>
    """
  end
end
