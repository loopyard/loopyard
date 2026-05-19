defmodule LoopyardWeb.ProjectLive do
  use LoopyardWeb, :live_view

  alias Loopyard.ProjectRegistry
  alias Loopyard.ChatAgent
  alias Loopyard.Events
  alias LoopyardWeb.ProjectLive.SectionLoader
  use LoopyardWeb.IExAware

  @behaviour Loopyard.Events.ChatAgent.Subscriber
  @behaviour Loopyard.Events.WorkspaceServices.Subscriber
  @behaviour Loopyard.Events.WorkspaceSetup.Subscriber

  @impl true
  def mount(%{"project_id" => project_id}, _session, socket) do
    project = ProjectRegistry.get_project(project_id)

    unless project do
      {:ok, push_navigate(socket, to: "/")}
    else
      if connected?(socket) do
        ChatAgent.subscribe()
        Loopyard.Workspace.ServiceManager.subscribe()
        # Subscribe to setup events globally so workspace cards reflect
        # in-flight Setup sagas without waiting for a card click.
        Loopyard.Events.WorkspaceSetup.subscribe_global()
        # Service/volume counts touch the filesystem and Docker — never
        # block mount on them. Render immediately with zeros, then fill
        # in via :fetch_service_counts.
        send(self(), :fetch_service_counts)
      end

      socket =
        if connected?(socket),
          do: subscribe_iex(socket),
          else: assign(socket, :iex_session, %{level: nil})

      # Seed counts with zeros so the template has safe keys to read.
      # The :agents section is cheap (ETS), load it synchronously. The
      # :fetch_service_counts message (sent above when connected) fills in
      # :services and :volumes via start_async — never blocks the LV.
      seeded =
        SectionLoader.load_workspaces(project, [:agents], SectionLoader.seed_defaults(project))

      {:ok,
       socket
       |> assign(:project, project)
       |> assign(:workspaces, seeded)
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

  def handle_async(:fill_sections, {:ok, workspaces}, socket) do
    {:noreply, assign(socket, :workspaces, workspaces)}
  end

  def handle_async(:fill_sections, {:exit, _reason}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("start_workspace", %{"id" => workspace_id}, socket) do
    workspace = ProjectRegistry.get_workspace(workspace_id)

    cond do
      is_nil(workspace) ->
        {:noreply, socket}

      not Loopyard.Workspace.ready?(workspace) ->
        # Setup saga is still running. Mutagen + seed rsync would race
        # if we let the cluster start now.
        {:noreply,
         put_flash(
           socket,
           :error,
           "Workspace is still being set up — wait for the volume seed to finish before starting the cluster."
         )}

      true ->
        Loopyard.WorkspaceSupervisor.start_workspace(workspace_id, workspace.path)
        ProjectRegistry.update_workspace_status(workspace_id, :running)

        {:noreply,
         assign(
           socket,
           :workspaces,
           SectionLoader.load_workspaces(socket.assigns.project, [:agents, :services, :volumes])
         )}
    end
  end

  @impl true
  def handle_event("stop_workspace", %{"id" => workspace_id}, socket) do
    Loopyard.WorkspaceSupervisor.stop_workspace(workspace_id)
    ProjectRegistry.update_workspace_status(workspace_id, :stopped)

    {:noreply,
     assign(
       socket,
       :workspaces,
       SectionLoader.load_workspaces(socket.assigns.project, [:agents, :services, :volumes])
     )}
  end

  @impl true
  def handle_event("add_workspace", params, socket) do
    name = String.trim(params["name"] || "")
    _from = String.trim(params["from"] || "main")

    if name != "" do
      # TODO: pass `from` to create_workspace so the branch is created off that base
      case ProjectRegistry.add_workspace(socket.assigns.project.id, name) do
        {:ok, workspace} ->
          {:noreply,
           push_navigate(socket,
             to: "/projects/#{socket.assigns.project.id}/workspaces/#{workspace.id}"
           )}

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
    Loopyard.WorkspaceSupervisor.stop_workspace(id)

    case ProjectRegistry.remove_workspace(id) do
      :ok ->
        {:noreply,
         assign(
           socket,
           :workspaces,
           SectionLoader.load_workspaces(socket.assigns.project, [:agents, :services, :volumes])
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  end

  # --- PubSub dispatch + non-PubSub internals ---

  @impl true
  def handle_info(%Events.ChatAgent.Started{} = e, socket), do: on_started(e, socket)
  def handle_info(%Events.ChatAgent.Stopped{} = e, socket), do: on_stopped(e, socket)
  def handle_info(%Events.ChatAgent.Booting{} = e, socket), do: on_booting(e, socket)
  def handle_info(%Events.ChatAgent.Removed{} = e, socket), do: on_removed(e, socket)
  def handle_info(%Events.ChatAgent.Resumed{} = e, socket), do: on_resumed(e, socket)
  def handle_info(%Events.ChatAgent.Renamed{} = e, socket), do: on_renamed(e, socket)
  def handle_info(%Events.ChatAgent.BootStatus{} = e, socket), do: on_boot_status(e, socket)
  def handle_info(%Events.ChatAgent.BootFailed{} = e, socket), do: on_boot_failed(e, socket)
  def handle_info(%Events.ChatAgent.StatusChanged{} = e, socket), do: on_status_changed(e, socket)
  def handle_info(%Events.ChatAgent.Quarantined{} = e, socket), do: on_quarantined(e, socket)
  def handle_info(%Events.ChatAgent.Released{} = e, socket), do: on_released(e, socket)

  def handle_info(%Events.WorkspaceServices.ServicesUpdated{} = e, socket),
    do: on_services_updated(e, socket)

  def handle_info(%Events.WorkspaceServices.ComposeResult{} = e, socket),
    do: on_compose_result(e, socket)

  def handle_info(%Events.WorkspaceSetup.Started{} = e, socket), do: on_setup_started(e, socket)

  def handle_info(%Events.WorkspaceSetup.PhaseStarted{} = e, socket),
    do: on_setup_phase_started(e, socket)

  def handle_info(%Events.WorkspaceSetup.PhaseCompleted{} = e, socket),
    do: on_setup_phase_completed(e, socket)

  def handle_info(%Events.WorkspaceSetup.PhaseProgress{} = e, socket),
    do: on_setup_phase_progress(e, socket)

  def handle_info(%Events.WorkspaceSetup.Completed{} = e, socket),
    do: on_setup_completed(e, socket)

  def handle_info(%Events.WorkspaceSetup.Failed{} = e, socket), do: on_setup_failed(e, socket)

  def handle_info(%Events.WorkspaceSetup.RetryScheduled{} = e, socket),
    do: on_setup_retry_scheduled(e, socket)

  def handle_info(:fetch_service_counts, socket) do
    # Initial async fill after mount. Load all three sections off the LV
    # process via start_async so a slow Docker call can't block message
    # processing. The result comes back through handle_async/:fill_sections.
    project = socket.assigns.project
    existing = socket.assigns.workspaces

    {:noreply,
     start_async(socket, :fill_sections, fn ->
       SectionLoader.load_workspaces(project, [:agents, :services, :volumes], existing)
     end)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- ChatAgent subscriber callbacks ---
  #
  # All agent lifecycle events that change the sidebar-card summary
  # route through the same agent-section merge. Don't re-walk
  # services/volumes — those are expensive docker calls and are
  # refreshed on the dedicated ServicesUpdated event.

  @impl Events.ChatAgent.Subscriber
  def on_started(_e, socket), do: refresh_agents(socket)
  @impl Events.ChatAgent.Subscriber
  def on_stopped(_e, socket), do: refresh_agents(socket)
  @impl Events.ChatAgent.Subscriber
  def on_booting(_e, socket), do: refresh_agents(socket)
  @impl Events.ChatAgent.Subscriber
  def on_removed(_e, socket), do: refresh_agents(socket)
  # Supervisor restart after a crash or log replay. Without this, a
  # workspace card stays showing the agent as :crashed even though the
  # new GenServer is alive — same root cause as the workspace-LV
  # sidebar sleepy-agent bug.
  @impl Events.ChatAgent.Subscriber
  def on_resumed(_e, socket), do: refresh_agents(socket)
  # Rename changes agent metadata we render in the card.
  @impl Events.ChatAgent.Subscriber
  def on_renamed(_e, socket), do: refresh_agents(socket)
  # Boot progress ticks through this; each change updates the
  # "Initializing…" label.
  @impl Events.ChatAgent.Subscriber
  def on_boot_status(_e, socket), do: refresh_agents(socket)
  # Boot blew up — badge needs to flip from :booting to the real
  # failure state so the user can retry.
  @impl Events.ChatAgent.Subscriber
  def on_boot_failed(_e, socket), do: refresh_agents(socket)
  @impl Events.ChatAgent.Subscriber
  def on_status_changed(_e, socket), do: refresh_agents(socket)

  @impl Events.ChatAgent.Subscriber
  def on_quarantined(_e, socket), do: {:noreply, socket}
  @impl Events.ChatAgent.Subscriber
  def on_released(_e, socket), do: {:noreply, socket}

  defp refresh_agents(socket) do
    {:noreply, assign(socket, :workspaces, SectionLoader.merge_sections(socket, [:agents]))}
  end

  # --- WorkspaceServices subscriber callbacks ---

  @impl Events.WorkspaceServices.Subscriber
  def on_services_updated(_e, socket) do
    # Services changed — agent_count and volume_count don't move because of this.
    {:noreply, assign(socket, :workspaces, SectionLoader.merge_sections(socket, [:services]))}
  end

  @impl Events.WorkspaceServices.Subscriber
  def on_compose_result(_e, socket) do
    # Compose result doesn't directly change what this page shows —
    # the service status broadcast follows and drives the refresh.
    {:noreply, socket}
  end

  # --- WorkspaceSetup subscriber callbacks ---
  #
  # All seven callbacks just patch the matching workspace's :setup field
  # in our :workspaces assign. The card pattern-matches on setup.phase
  # to decide which dot color and status text to render.

  @impl Events.WorkspaceSetup.Subscriber
  def on_setup_started(
        %Events.WorkspaceSetup.Started{workspace_id: id, attempt: attempt, started_at: at},
        socket
      ) do
    {:noreply,
     patch_workspace_setup(socket, id, %{
       phase: :running,
       attempts: attempt,
       started_at: at,
       error: nil
     })}
  end

  @impl Events.WorkspaceSetup.Subscriber
  def on_setup_phase_started(
        %Events.WorkspaceSetup.PhaseStarted{workspace_id: id, phase: phase},
        socket
      ) do
    {:noreply, patch_workspace_setup(socket, id, %{phase: phase})}
  end

  @impl Events.WorkspaceSetup.Subscriber
  def on_setup_phase_completed(%Events.WorkspaceSetup.PhaseCompleted{}, socket),
    do: {:noreply, socket}

  @impl Events.WorkspaceSetup.Subscriber
  def on_setup_phase_progress(
        %Events.WorkspaceSetup.PhaseProgress{workspace_id: id, payload: payload},
        socket
      ) do
    {:noreply, patch_workspace_setup(socket, id, %{progress: payload})}
  end

  @impl Events.WorkspaceSetup.Subscriber
  def on_setup_completed(
        %Events.WorkspaceSetup.Completed{workspace_id: id, finished_at: at},
        socket
      ) do
    {:noreply, patch_workspace_setup(socket, id, %{phase: :ready, finished_at: at, error: nil})}
  end

  @impl Events.WorkspaceSetup.Subscriber
  def on_setup_failed(%Events.WorkspaceSetup.Failed{workspace_id: id, error: error}, socket) do
    {:noreply,
     patch_workspace_setup(socket, id, %{
       phase: :failed,
       error: error,
       finished_at: DateTime.utc_now()
     })}
  end

  @impl Events.WorkspaceSetup.Subscriber
  def on_setup_retry_scheduled(%Events.WorkspaceSetup.RetryScheduled{}, socket),
    do: {:noreply, socket}

  defp patch_workspace_setup(socket, workspace_id, changes) do
    workspaces =
      Enum.map(socket.assigns.workspaces, fn ws ->
        if ws.id == workspace_id do
          new_setup = Map.merge(Map.get(ws, :setup, %{}) || %{}, changes)
          Map.put(ws, :setup, new_setup)
        else
          ws
        end
      end)

    assign(socket, :workspaces, workspaces)
  end

  defp removal_details(project) do
    # For volume-based projects, use the workspace dir
    ws_ids = ProjectRegistry.list_workspaces(project.id) |> Enum.map(& &1.id)

    project_dir =
      project[:path] || (ws_ids != [] && Loopyard.Workspace.compose_dir(hd(ws_ids))) ||
        "unknown"

    loopyard_dir = Path.join(project_dir, ".loopyard")
    workspace_dir = Path.join(loopyard_dir, "workspace")

    files =
      if File.dir?(workspace_dir) do
        case File.ls(workspace_dir) do
          {:ok, entries} -> Enum.map(entries, &Path.join(".loopyard/workspace", &1))
          _ -> []
        end
      else
        []
      end

    config_exists = File.exists?(Path.join(loopyard_dir, "repo/workspace.json"))

    containers =
      ProjectRegistry.list_workspaces(project.id)
      |> Enum.flat_map(fn ws ->
        # ws.path is normalized by ProjectRegistry for all workspace types
        prefix = Loopyard.Compose.project_name(ws.id)

        case Loopyard.Compose.ps(ws.path, ws.id) do
          {:ok, services} -> Enum.map(services, fn s -> "#{prefix}-#{s.name}-1" end)
          _ -> []
        end
      end)

    %{
      loopyard_dir: shorten_path(loopyard_dir),
      generated_files: files,
      config_exists: config_exists,
      containers: containers
    }
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_shell
      breadcrumbs={breadcrumbs_for(assigns)}
      iex_session={@iex_session}
      max_width={:md}
      flash={@flash}
    >
      <%= if @removing do %>
        <div class="text-center py-16">
          <div class="inline-block w-6 h-6 border-2 border-zinc-300 dark:border-zinc-600 border-t-violet-500 rounded-full animate-spin mb-4">
          </div>
          <h2 class="text-lg font-semibold text-zinc-600 dark:text-zinc-300">
            Removing {@project.name}...
          </h2>
          <p class="text-sm text-zinc-400 dark:text-zinc-500 mt-1">
            Stopping containers and cleaning up volumes
          </p>
        </div>
      <% else %>
        <%= if @live_action == :settings do %>
          <%= if @confirming_remove do %>
            <.remove_confirmation project={@project} details={removal_details(@project)} />
          <% else %>
            <.settings_view project={@project} />
          <% end %>
        <% else %>
          <%= if @confirming_remove do %>
            <.remove_confirmation project={@project} details={removal_details(@project)} />
          <% else %>
            <div class="flex items-center justify-between mb-6 gap-4">
              <div class="min-w-0 flex-1">
                <%= if @editing_name do %>
                  <form
                    phx-submit="rename_project"
                    phx-click-away="cancel_rename"
                    class="flex items-center gap-2"
                  >
                    <input
                      type="text"
                      name="name"
                      value={@project.name}
                      autocomplete="off"
                      autofocus
                      phx-keydown="cancel_rename"
                      phx-key="Escape"
                      class="text-xl font-semibold bg-transparent border-b-2 border-violet-400 focus:outline-none focus:border-violet-500 px-0 py-0.5 min-w-0 flex-1
                             text-zinc-900 dark:text-zinc-100"
                    />
                    <button
                      type="submit"
                      class="text-xs font-medium text-violet-600 dark:text-violet-400 hover:text-violet-500 transition-colors flex-none"
                    >
                      Save
                    </button>
                    <button
                      type="button"
                      phx-click="cancel_rename"
                      class="text-xs font-medium text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-300 transition-colors flex-none"
                    >
                      Cancel
                    </button>
                  </form>
                <% else %>
                  <button
                    phx-click="start_rename"
                    class="group flex items-center gap-2 text-left hover:text-violet-600 dark:hover:text-violet-400 transition-colors"
                    title="Rename project"
                  >
                    <h2 class="text-xl font-semibold truncate">{@project.name}</h2>
                    <svg
                      xmlns="http://www.w3.org/2000/svg"
                      viewBox="0 0 20 20"
                      fill="currentColor"
                      class="w-3.5 h-3.5 text-zinc-300 dark:text-zinc-600 opacity-0 group-hover:opacity-100 transition-opacity flex-none"
                    >
                      <path d="M2.695 14.762l-1.262 3.155a.5.5 0 00.65.65l3.155-1.262a4 4 0 001.343-.886L17.5 5.501a2.121 2.121 0 00-3-3L3.58 13.419a4 4 0 00-.885 1.343z" />
                    </svg>
                  </button>
                <% end %>
                <p class="text-xs font-mono text-zinc-400 dark:text-zinc-500 mt-0.5 truncate">
                  {project_location(@project)}
                </p>
              </div>
              <button
                phx-click="confirm_remove"
                class="text-xs font-medium text-zinc-400 dark:text-zinc-500 hover:text-red-500 dark:hover:text-red-400 transition-colors flex-none"
              >
                Remove project
              </button>
            </div>

            <div class="space-y-2 mb-8">
              <.link
                :for={workspace <- @workspaces}
                navigate={"/projects/#{@project.id}/workspaces/#{workspace.id}"}
                class={[
                  "block rounded-xl border p-4 transition-colors",
                  if(workspace.status == :running,
                    do:
                      "border-green-300 dark:border-green-800 bg-green-50/50 dark:bg-green-950/20 hover:border-green-400",
                    else:
                      "border-zinc-200 dark:border-zinc-700 hover:border-violet-400 dark:hover:border-violet-500 hover:bg-zinc-50 dark:hover:bg-zinc-800/50"
                  )
                ]}
              >
                <div class="flex items-center gap-3">
                  <div class={"w-2.5 h-2.5 rounded-full flex-none #{cond do
                    Map.get(workspace, :setup, %{})[:phase] == :running -> "bg-blue-500 animate-pulse"
                    Map.get(workspace, :setup, %{})[:phase] == :pending -> "bg-blue-300 animate-pulse"
                    Map.get(workspace, :setup, %{})[:phase] == :failed -> "bg-red-500"
                    workspace.status == :running -> "bg-green-500"
                    true -> "bg-zinc-400"
                  end}"}>
                  </div>
                  <div class="min-w-0 flex-1">
                    <div class="flex items-center gap-2">
                      <span class="text-sm font-medium text-zinc-900 dark:text-zinc-100 truncate">
                        {workspace.name}
                      </span>
                      <span
                        :if={workspace[:is_main]}
                        class="text-[10px] uppercase tracking-wider text-zinc-400 dark:text-zinc-500 flex-none"
                      >
                        default
                      </span>
                    </div>
                    <% setup = Map.get(workspace, :setup, %{}) %>
                    <% setup_phase = setup[:phase] %>
                    <p
                      :if={setup_phase in [:pending, :running, :worktree, :volume, :seeding]}
                      class="text-xs text-blue-600 dark:text-blue-400 mt-0.5"
                    >
                      <%= case setup_phase do %>
                        <% :pending -> %>
                          Setting up workspace…
                        <% :running -> %>
                          Setting up workspace…
                        <% :worktree -> %>
                          Creating worktree…
                        <% :volume -> %>
                          Creating volume…
                        <% :seeding -> %>
                          <% pct = get_in(setup, [:progress, :percent]) %>
                          {if pct, do: "Seeding files… #{pct}%", else: "Seeding files…"}
                      <% end %>
                    </p>
                    <p
                      :if={setup_phase == :failed}
                      class="text-xs text-red-600 dark:text-red-400 mt-0.5"
                    >
                      Failed — click to retry
                    </p>
                    <p
                      :if={setup_phase in [:ready, nil] && workspace.status == :running}
                      class="text-xs text-zinc-500 dark:text-zinc-400 mt-0.5"
                    >
                      {workspace.agent_count} agent{if workspace.agent_count != 1, do: "s"} · {workspace.services_running} service{if workspace.services_running !=
                                                                                                                                        1,
                                                                                                                                      do:
                                                                                                                                        "s"} running
                    </p>
                    <p
                      :if={setup_phase in [:ready, nil] && workspace.status != :running}
                      class="text-xs text-zinc-400 dark:text-zinc-500 mt-0.5"
                    >
                      Stopped
                    </p>
                  </div>
                  <svg
                    xmlns="http://www.w3.org/2000/svg"
                    viewBox="0 0 16 16"
                    fill="currentColor"
                    class="w-4 h-4 text-zinc-300 dark:text-zinc-600 flex-none"
                  >
                    <path
                      fill-rule="evenodd"
                      d="M6.22 4.22a.75.75 0 0 1 1.06 0l3.25 3.25a.75.75 0 0 1 0 1.06l-3.25 3.25a.75.75 0 0 1-1.06-1.06L8.94 8 6.22 5.28a.75.75 0 0 1 0-1.06Z"
                      clip-rule="evenodd"
                    />
                  </svg>
                </div>
              </.link>
            </div>

            <% default_branch = get_in(@project, [:source_config, :default_branch]) || "main" %>
            <form :if={@project.is_git} phx-submit="add_workspace" class="space-y-3">
              <div class="text-xs font-medium text-zinc-500 dark:text-zinc-400">New workspace</div>
              <div class="space-y-2">
                <div>
                  <label class="block text-xs text-zinc-400 dark:text-zinc-500 mb-1">
                    Branch from
                  </label>
                  <input
                    type="text"
                    name="from"
                    value={default_branch}
                    autocomplete="off"
                    class="w-full rounded-lg border border-zinc-300 dark:border-zinc-600 bg-zinc-50 dark:bg-zinc-800/50 px-3 py-2 text-sm font-mono
                           text-zinc-600 dark:text-zinc-300
                           focus:outline-none focus:ring-2 focus:ring-violet-500/20 focus:border-violet-400"
                  />
                </div>
                <div>
                  <label class="block text-xs text-zinc-400 dark:text-zinc-500 mb-1">
                    New branch name
                  </label>
                  <input
                    type="text"
                    name="name"
                    placeholder="e.g. bradgessler/fix-login"
                    autocomplete="off"
                    class="w-full rounded-lg border border-zinc-300 dark:border-zinc-600 bg-white dark:bg-zinc-800 px-3 py-2 text-sm font-mono
                           text-zinc-600 dark:text-zinc-300 placeholder:text-zinc-400
                           focus:outline-none focus:ring-2 focus:ring-violet-500/20 focus:border-violet-400"
                  />
                </div>
              </div>
              <button
                type="submit"
                class="rounded-lg border border-zinc-200 dark:border-zinc-700 px-5 py-2.5 text-sm font-medium text-zinc-600 dark:text-zinc-400
                       hover:bg-zinc-100 dark:hover:bg-zinc-800 transition-colors"
              >
                Create workspace
              </button>
            </form>
          <% end %>
        <% end %>
      <% end %>
    </.page_shell>
    """
  end

  defp breadcrumbs_for(%{live_action: :settings, project: project}) do
    [{"Loopyard", "/"}, {project.name, "/projects/#{project.id}"}, {"Settings", nil}]
  end

  defp breadcrumbs_for(%{project: project}) do
    [{"Loopyard", "/"}, {project.name, nil}]
  end

  defp settings_view(assigns) do
    ~H"""
    <div class="space-y-8">
      <div>
        <h2 class="text-xl font-semibold text-zinc-900 dark:text-zinc-100">Project settings</h2>
        <p class="text-sm text-zinc-500 dark:text-zinc-400 mt-1">
          {@project.name}
        </p>
      </div>

      <form phx-submit="rename_project" class="space-y-2">
        <label for="project-name" class="block text-xs font-medium text-zinc-500 dark:text-zinc-400">
          Name
        </label>
        <input
          id="project-name"
          type="text"
          name="name"
          value={@project.name}
          autocomplete="off"
          class="w-full rounded-lg border border-zinc-300 dark:border-zinc-600 bg-white dark:bg-zinc-800 px-3 py-2.5 text-base
                 text-zinc-900 dark:text-zinc-100
                 focus:outline-none focus:ring-2 focus:ring-violet-500/20 focus:border-violet-400"
        />
        <div class="pt-1">
          <button
            type="submit"
            class="rounded-lg bg-violet-600 hover:bg-violet-700 text-white text-sm font-medium px-4 py-2 transition-colors"
          >
            Save name
          </button>
        </div>
      </form>

      <div class="space-y-2">
        <div class="text-xs font-medium text-zinc-500 dark:text-zinc-400">Location</div>
        <p class="text-sm font-mono text-zinc-600 dark:text-zinc-300 break-all">
          {project_location(@project)}
        </p>
      </div>

      <div class="pt-6 border-t border-zinc-200 dark:border-zinc-700/80 space-y-2">
        <div class="text-xs font-semibold uppercase tracking-wider text-red-500 dark:text-red-400">
          Danger zone
        </div>
        <p class="text-sm text-zinc-500 dark:text-zinc-400">
          Remove this project from Loopyard. Your source code on disk is not affected.
        </p>
        <button
          phx-click="confirm_remove"
          class="rounded-lg border border-red-300 dark:border-red-800 text-red-600 dark:text-red-400 text-sm font-medium px-4 py-2 hover:bg-red-50 dark:hover:bg-red-950/30 transition-colors"
        >
          Remove project
        </button>
      </div>
    </div>
    """
  end

  defp remove_confirmation(assigns) do
    ~H"""
    <div class="space-y-6">
      <div>
        <h2 class="text-xl font-semibold text-red-600 dark:text-red-400">Remove {@project.name}</h2>
        <p class="text-sm text-zinc-500 dark:text-zinc-400 mt-1">
          This will permanently remove the project from Loopyard. Your source code is not affected.
        </p>
      </div>

      <div class="rounded-lg border border-zinc-200 dark:border-zinc-700 divide-y divide-zinc-200 dark:divide-zinc-700">
        <div class="px-4 py-3">
          <div class="text-xs font-semibold uppercase tracking-wider text-zinc-400 dark:text-zinc-500 mb-2">
            Directory to delete
          </div>
          <p class="text-sm font-mono text-zinc-600 dark:text-zinc-400">{@details.loopyard_dir}/</p>
          <ul :if={@details.generated_files != []} class="mt-1.5 space-y-0.5">
            <li
              :for={file <- @details.generated_files}
              class="text-xs font-mono text-zinc-400 dark:text-zinc-500 pl-4"
            >
              {file}
            </li>
          </ul>
          <p :if={@details.config_exists} class="text-xs text-amber-600 dark:text-amber-400 mt-1.5">
            Includes workspace.json config (workspace settings, Dockerfile, services)
          </p>
        </div>

        <div class="px-4 py-3">
          <div class="text-xs font-semibold uppercase tracking-wider text-zinc-400 dark:text-zinc-500 mb-2">
            Docker containers to stop
          </div>
          <%= if @details.containers != [] do %>
            <ul class="space-y-0.5">
              <li
                :for={container <- @details.containers}
                class="text-sm font-mono text-zinc-600 dark:text-zinc-400"
              >
                {container}
              </li>
            </ul>
          <% else %>
            <p class="text-sm text-zinc-400 dark:text-zinc-500">No running containers</p>
          <% end %>
        </div>
      </div>

      <div class="flex items-center gap-3">
        <button
          phx-click="remove_project"
          class="rounded-lg bg-red-600 hover:bg-red-700 text-white text-sm font-medium px-4 py-2 transition-colors"
        >
          Remove project
        </button>
        <button
          phx-click="cancel_remove"
          class="text-sm font-medium text-zinc-500 dark:text-zinc-400 hover:text-zinc-700 dark:hover:text-zinc-200 transition-colors"
        >
          Cancel
        </button>
      </div>
    </div>
    """
  end
end
