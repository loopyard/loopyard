defmodule LoopyardWeb.ProjectListLive do
  use LoopyardWeb, :live_view
  use LoopyardWeb.IExAware

  alias Loopyard.ProjectRegistry

  @impl true
  @behaviour Loopyard.Events.Projects.Subscriber

  def mount(_params, _session, socket) do
    socket =
      if connected?(socket) do
        # Multiplayer: a project anyone creates/removes shows up in this list live.
        Loopyard.Events.Projects.subscribe()
        subscribe_iex(socket)
      else
        assign(socket, :iex_session, %{level: nil})
      end

    secret = Application.get_env(:loopyard, :launch_secret, "")
    port = Application.get_env(:loopyard, LoopyardWeb.Endpoint)[:http][:port] || 4000
    launch_cmd = "open \"http://localhost:#{port}/launch/#{secret}?path=$(pwd)\""

    {:ok,
     socket
     |> assign(:projects, load_projects())
     |> assign(:launch_cmd, launch_cmd)
     |> assign(:creating, nil)}
  end

  @impl true
  def handle_event("create_project", %{"name" => name}, socket) do
    name = String.trim(name)

    cond do
      name == "" ->
        {:noreply, put_flash(socket, :error, "Name your project")}

      socket.assigns.creating ->
        # Already creating — ignore the double-submit.
        {:noreply, socket}

      true ->
        # Creating a canonical project does a couple seconds of Docker/git work.
        # Run it OFF the LiveView process so the UI stays responsive (shows a
        # "Creating…" state) instead of freezing; navigate when it's done.
        lv = self()

        Task.Supervisor.start_child(Loopyard.TaskSupervisor, fn ->
          send(lv, {:project_created, Loopyard.Onboarding.create_project(name)})
        end)

        {:noreply, assign(socket, :creating, name)}
    end
  end

  @impl true
  def handle_event("add_project", %{"path" => path}, socket) do
    path = String.trim(path)

    if path == "" do
      {:noreply, put_flash(socket, :error, "Enter a project path")}
    else
      case ProjectRegistry.add(path) do
        {:ok, project, workspace} ->
          {:noreply,
           push_navigate(socket, to: "/projects/#{project.id}/workspaces/#{workspace.id}")}

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
  def handle_info({:project_created, {:ok, project, ws}}, socket) do
    {:noreply, push_navigate(socket, to: "/projects/#{project.id}/workspaces/#{ws.id}")}
  end

  def handle_info({:project_created, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:creating, nil)
     |> put_flash(:error, "Couldn't create project: #{inspect(reason)}")}
  end

  def handle_info(%Loopyard.Events.Projects.Changed{} = e, socket), do: on_changed(e, socket)

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl Loopyard.Events.Projects.Subscriber
  def on_changed(_e, socket), do: {:noreply, assign(socket, :projects, load_projects())}

  defp load_projects do
    ProjectRegistry.list_projects()
    |> Enum.map(fn project ->
      workspaces = ProjectRegistry.list_workspaces(project.id)
      Map.put(project, :workspace_count, length(workspaces))
    end)
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :has_projects, assigns.projects != [])

    ~H"""
    <.page_shell
      breadcrumbs={crumbs(@live_action)}
      iex_session={@iex_session}
      max_width={:xl}
      flash={@flash}
    >
      <%= case @live_action do %>
        <% :index -> %>
          <.section_header title="Projects">
            <:action>
              <.new_button navigate="/projects/new">New project</.new_button>
            </:action>
          </.section_header>

          <.card_grid :if={@has_projects}>
            <.tile_card :for={project <- @projects} navigate={"/projects/#{project.id}"}>
              <h3 class="text-base font-semibold truncate">{project.name}</h3>
              <p class="text-xs md:text-sm font-mono text-zinc-400 dark:text-zinc-500 mt-1 truncate">
                {project_location(project)}
              </p>
              <p
                :if={project.workspace_count > 1}
                class="text-xs text-zinc-400 dark:text-zinc-500 mt-2"
              >
                {project.workspace_count} workspaces
              </p>
            </.tile_card>
          </.card_grid>

          <div
            :if={!@has_projects}
            class="text-center py-16 md:py-24 text-sm text-zinc-400 dark:text-zinc-500"
          >
            No projects yet — hit
            <span class="font-medium text-zinc-500 dark:text-zinc-400">New project</span>
            to start.
          </div>
        <% :new -> %>
          <div class="max-w-2xl">
            <h1 class="text-xl font-semibold mb-1">New project</h1>
            <p class="text-sm text-zinc-500 dark:text-zinc-400 mb-5">How do you want to start?</p>
            <div class="space-y-2.5">
              <.method_card
                navigate="/projects/new/scratch"
                title="From scratch"
                desc="Name it and start building — a fresh repo, ready instantly."
              />
              <.method_card
                navigate="/projects/new/folder"
                title="From a folder on this machine"
                desc="Bring in code you already have on disk."
              />
              <.method_card
                navigate="/projects/new/github"
                title="From GitHub"
                desc="Clone a repo to start, sync back as it matures."
                badge="Soon"
              />
            </div>
          </div>
        <% :new_scratch -> %>
          <div class="max-w-2xl">
            <h1 class="text-xl font-semibold mb-1">From scratch</h1>
            <p class="text-sm text-zinc-500 dark:text-zinc-400 mb-5">
              A fresh repo, ready instantly. No GitHub needed — connect one later when it matters.
            </p>
            <form phx-submit="create_project" class="space-y-3">
              <input
                type="text"
                name="name"
                placeholder="my-idea"
                autocomplete="off"
                autofocus
                disabled={@creating != nil}
                value={@creating}
                class="w-full rounded-lg border border-zinc-300 dark:border-zinc-600 bg-white dark:bg-zinc-900 px-3 py-2.5 text-sm
                     text-zinc-900 dark:text-zinc-200 placeholder:text-zinc-400 dark:placeholder:text-zinc-600 disabled:opacity-60
                     focus:outline-none focus:ring-1 focus:ring-violet-500/30 focus:border-violet-400"
              />
              <button
                type="submit"
                disabled={@creating != nil}
                class="focus-ring w-full inline-flex items-center justify-center gap-1.5 rounded-lg bg-violet-600 hover:bg-violet-700 disabled:opacity-70 px-5 py-2.5 text-sm font-semibold text-white transition-colors"
              >
                <svg
                  :if={@creating}
                  class="w-4 h-4 animate-spin"
                  xmlns="http://www.w3.org/2000/svg"
                  fill="none"
                  viewBox="0 0 24 24"
                >
                  <circle
                    class="opacity-25"
                    cx="12"
                    cy="12"
                    r="10"
                    stroke="currentColor"
                    stroke-width="4"
                  >
                  </circle>
                  <path
                    class="opacity-75"
                    fill="currentColor"
                    d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
                  >
                  </path>
                </svg>
                {if @creating, do: "Creating…", else: "Create project"}
              </button>
            </form>
          </div>
        <% :new_folder -> %>
          <div class="max-w-2xl">
            <h1 class="text-xl font-semibold mb-1">From a folder on this machine</h1>
            <p class="text-sm text-zinc-500 dark:text-zinc-400 mb-5">
              Point Loopyard at a directory you already have.
            </p>
            <form phx-submit="add_project" class="flex items-center gap-2 mb-5">
              <input
                type="text"
                name="path"
                placeholder="/Users/you/projects/my-app"
                autocomplete="off"
                autofocus
                class="flex-1 min-w-0 rounded-lg border border-zinc-300 dark:border-zinc-600 bg-white dark:bg-zinc-900 px-3 py-2.5 text-sm font-mono
                     text-zinc-900 dark:text-zinc-300 placeholder:text-zinc-400 dark:placeholder:text-zinc-600
                     focus:outline-none focus:ring-1 focus:ring-violet-500/20 focus:border-violet-400"
              />
              <button
                type="submit"
                class="focus-ring flex-none rounded-lg bg-zinc-900 dark:bg-zinc-200 hover:bg-zinc-800 dark:hover:bg-white px-5 py-2.5 text-sm font-semibold text-white dark:text-zinc-900 transition-colors"
              >
                Open
              </button>
            </form>
            <div class="rounded-xl border border-zinc-200 dark:border-zinc-700 bg-zinc-50 dark:bg-zinc-800/50 p-4">
              <p class="text-[11px] text-zinc-400 dark:text-zinc-500 mb-1.5">
                Or run this from that folder in your terminal:
              </p>
              <div class="flex items-center gap-2">
                <div class="flex-1 min-w-0 bg-zinc-900 dark:bg-zinc-950 rounded-lg px-3 py-1.5 font-mono text-[11px] text-zinc-300 overflow-x-auto whitespace-nowrap select-all">
                  <span class="text-zinc-500 select-none">$ </span>{@launch_cmd}
                </div>
                <button
                  id="copy-launch"
                  phx-hook="CopySource"
                  data-source={@launch_cmd}
                  class="flex-none rounded-lg border border-zinc-300 dark:border-zinc-600 hover:bg-zinc-100 dark:hover:bg-zinc-700 px-3 py-1.5 text-xs font-medium text-zinc-600 dark:text-zinc-300 transition-colors"
                >
                  Copy
                </button>
              </div>
            </div>
          </div>
        <% :new_github -> %>
          <div class="max-w-2xl">
            <h1 class="text-xl font-semibold mb-1 flex items-center gap-2">
              From GitHub
              <span class="text-[10px] font-medium uppercase tracking-wide rounded-full bg-zinc-200 dark:bg-zinc-700 text-zinc-500 dark:text-zinc-400 px-2 py-0.5">
                Soon
              </span>
            </h1>
            <p class="text-sm text-zinc-500 dark:text-zinc-400 mb-5">
              Clone a repo to start, and sync back as it matures. The engine's built — the UI is next.
            </p>
            <div class="rounded-xl border border-dashed border-zinc-300 dark:border-zinc-700 p-8 text-center text-sm text-zinc-400 dark:text-zinc-500">
              Coming soon.
            </div>
          </div>
      <% end %>
    </.page_shell>
    """
  end

  # A single creation-method row on the /projects/new menu.
  attr :navigate, :string, required: true
  attr :title, :string, required: true
  attr :desc, :string, required: true
  attr :badge, :string, default: nil

  defp method_card(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class="flex items-center justify-between gap-3 w-full rounded-xl border border-zinc-200 dark:border-zinc-700 p-4 hover:border-violet-400 dark:hover:border-violet-500 hover:bg-zinc-50 dark:hover:bg-zinc-800/50 transition-colors group"
    >
      <div class="min-w-0">
        <div class="flex items-center gap-2">
          <span class="text-sm font-semibold">{@title}</span>
          <span
            :if={@badge}
            class="text-[10px] font-medium uppercase tracking-wide rounded-full bg-zinc-200 dark:bg-zinc-700 text-zinc-500 dark:text-zinc-400 px-1.5 py-0.5"
          >
            {@badge}
          </span>
        </div>
        <p class="text-xs text-zinc-500 dark:text-zinc-400 mt-0.5">{@desc}</p>
      </div>
      <.chevron />
    </.link>
    """
  end

  defp crumbs(:index), do: [{"Loopyard", nil}]
  defp crumbs(:new), do: [{"Loopyard", "/"}, {"New project", nil}]

  defp crumbs(:new_scratch),
    do: [{"Loopyard", "/"}, {"New project", "/projects/new"}, {"From scratch", nil}]

  defp crumbs(:new_folder),
    do: [{"Loopyard", "/"}, {"New project", "/projects/new"}, {"Folder", nil}]

  defp crumbs(:new_github),
    do: [{"Loopyard", "/"}, {"New project", "/projects/new"}, {"GitHub", nil}]

  defp crumbs(_), do: [{"Loopyard", nil}]
end
