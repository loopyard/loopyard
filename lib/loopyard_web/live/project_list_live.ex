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
    has_projects = assigns.projects != []
    assigns = assign(assigns, :has_projects, has_projects)

    ~H"""
    <.page_shell
      breadcrumbs={[{"Loopyard", nil}]}
      iex_session={@iex_session}
      max_width={:sm}
      flash={@flash}
    >
      <%!-- Primary CTA: start a brand-new project, zero friction --%>
      <div class="mb-6">
        <form
          phx-submit="create_project"
          class="rounded-xl border border-violet-200 dark:border-violet-800/60 bg-violet-50/60 dark:bg-violet-900/10 p-5"
        >
          <h2 class="text-lg font-semibold mb-1">Start a new project</h2>
          <p class="text-sm text-zinc-500 dark:text-zinc-400 mb-3">
            Name it and start building — a fresh repo, ready instantly. No GitHub needed;
            connect one later when it matters.
          </p>
          <div class="flex items-center gap-2">
            <input
              type="text"
              name="name"
              placeholder="my-idea"
              autocomplete="off"
              autofocus
              disabled={@creating != nil}
              value={@creating}
              class="flex-1 rounded-lg border border-zinc-300 dark:border-zinc-600 bg-white dark:bg-zinc-900 px-3 py-2 text-sm
                     text-zinc-900 dark:text-zinc-200 placeholder:text-zinc-400 dark:placeholder:text-zinc-600 disabled:opacity-60
                     focus:outline-none focus:ring-1 focus:ring-violet-500/30 focus:border-violet-400"
            />
            <button
              type="submit"
              disabled={@creating != nil}
              class="flex-none inline-flex items-center gap-1.5 rounded-lg bg-violet-600 hover:bg-violet-700 disabled:opacity-70 disabled:hover:bg-violet-600 px-5 py-2 text-sm font-semibold text-white transition-colors"
            >
              <%= if @creating do %>
                <svg
                  class="w-4 h-4 animate-spin"
                  xmlns="http://www.w3.org/2000/svg"
                  fill="none"
                  viewBox="0 0 24 24"
                  aria-hidden="true"
                >
                  <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4">
                  </circle>
                  <path
                    class="opacity-75"
                    fill="currentColor"
                    d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
                  >
                  </path>
                </svg>
                Creating…
              <% else %>
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  viewBox="0 0 20 20"
                  fill="currentColor"
                  class="w-4 h-4"
                  aria-hidden="true"
                >
                  <path d="M10.75 4.75a.75.75 0 0 0-1.5 0v4.5h-4.5a.75.75 0 0 0 0 1.5h4.5v4.5a.75.75 0 0 0 1.5 0v-4.5h4.5a.75.75 0 0 0 0-1.5h-4.5v-4.5Z" />
                </svg>
                Create
              <% end %>
            </button>
          </div>
        </form>
      </div>

      <%!-- Empty state --%>
      <div :if={!@has_projects} class="mb-8">
        <p class="text-sm text-zinc-500 dark:text-zinc-400 leading-relaxed">
          Or bring in an existing project — point Loopyard at a directory on this machine
          (paste a path or use the terminal command below).
        </p>
      </div>

      <%!-- Existing projects --%>
      <div :if={@has_projects} class="space-y-2 mb-6">
        <.link
          :for={project <- @projects}
          navigate={"/projects/#{project.id}"}
          class="block w-full rounded-xl border border-zinc-200 dark:border-zinc-700 p-4 hover:border-violet-400 dark:hover:border-violet-500 hover:bg-zinc-50 dark:hover:bg-zinc-800/50 transition-colors group"
        >
          <div class="flex items-center justify-between">
            <div class="min-w-0">
              <div class="flex items-center gap-2">
                <span class="text-sm font-semibold truncate">{project.name}</span>
                <span
                  :if={project.workspace_count > 1}
                  class="text-xs text-zinc-400 dark:text-zinc-500"
                >
                  {project.workspace_count} workspaces
                </span>
              </div>
              <p class="text-xs font-mono text-zinc-400 dark:text-zinc-500 mt-0.5 truncate">
                {project_location(project)}
              </p>
            </div>
            <svg
              xmlns="http://www.w3.org/2000/svg"
              viewBox="0 0 16 16"
              fill="currentColor"
              class="w-3.5 h-3.5 text-zinc-300 dark:text-zinc-600 group-hover:text-zinc-500 dark:group-hover:text-zinc-400 transition-colors flex-none"
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

      <%!-- Add project --%>
      <div :if={@has_projects} class="mb-3">
        <h2 class="text-lg font-semibold">Add a project</h2>
      </div>

      <div class="space-y-3">
        <%!-- Option: Terminal command --%>
        <div class="rounded-xl border border-zinc-200 dark:border-zinc-700 bg-zinc-50 dark:bg-zinc-800/50 p-5 flex flex-col">
          <h3 class="text-sm font-semibold mb-1">From terminal</h3>
          <p class="text-xs text-zinc-500 dark:text-zinc-400 mb-3">
            <code class="text-zinc-700 dark:text-zinc-300">cd</code>
            into your project and run this command.
          </p>
          <div class="flex items-center gap-2 mt-auto">
            <div class="flex-1 bg-zinc-900 dark:bg-zinc-950 border border-zinc-200 dark:border-zinc-700 rounded-lg px-3 py-2 font-mono text-xs text-zinc-300 overflow-x-auto whitespace-nowrap select-all">
              <span class="text-zinc-500 select-none">$ </span>{@launch_cmd}
            </div>
            <button
              id="copy-launch"
              phx-hook="CopySource"
              data-source={@launch_cmd}
              class="flex-none rounded-lg bg-zinc-900 dark:bg-zinc-200 hover:bg-zinc-800 dark:hover:bg-white px-4 py-2 text-sm font-semibold text-white dark:text-zinc-900 transition-colors"
            >
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
            <input
              type="text"
              name="path"
              placeholder="/Users/you/projects/my-app"
              autocomplete="off"
              class="flex-1 rounded-lg border border-zinc-300 dark:border-zinc-600 bg-white dark:bg-zinc-900 px-3 py-2 text-sm font-mono
                         text-zinc-900 dark:text-zinc-300 placeholder:text-zinc-400 dark:placeholder:text-zinc-600
                         focus:outline-none focus:ring-1 focus:ring-violet-500/20 focus:border-violet-400"
            />
            <button
              type="submit"
              class="rounded-lg bg-zinc-900 dark:bg-zinc-200 hover:bg-zinc-800 dark:hover:bg-white px-4 py-2 text-sm font-semibold text-white dark:text-zinc-900 transition-colors flex-none"
            >
              Launch
            </button>
          </form>
        </div>
      </div>
    </.page_shell>
    """
  end
end
