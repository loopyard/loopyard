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
        # Live agent status + current activity on the birdseye (dots + "editing…"
        # update live as agents work).
        Loopyard.Events.Activity.subscribe_global()
        # Live ports: a service coming up / port being exposed refreshes the
        # openable :port chips without a reload.
        Loopyard.Events.DockerObserver.subscribe()
        subscribe_iex(socket)
      else
        assign(socket, :iex_session, %{level: nil})
      end

    # Build openable port URLs from the same host the browser is on (LAN IP or
    # localhost), so the :port chips work wherever Loopyard is reached from.
    host =
      case socket.host_uri do
        %URI{host: h} when is_binary(h) and h != "" -> h
        _ -> "localhost"
      end

    secret = Application.get_env(:loopyard, :launch_secret, "")
    port = Application.get_env(:loopyard, LoopyardWeb.Endpoint)[:http][:port] || 4000
    launch_cmd = "open \"http://localhost:#{port}/launch/#{secret}?path=$(pwd)\""

    {:ok,
     socket
     |> assign(:host, host)
     |> assign(:projects, load_birdseye(host))
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
    {:noreply, reload(socket)}
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

  # Any agent activity (status OR a tool call) → refresh the birdseye so dots +
  # "what it's doing" lines stay live.
  def handle_info(%Loopyard.Events.Activity.Event{}, socket), do: {:noreply, reload(socket)}

  # Container/port state changed → refresh so the openable :port chips are current.
  def handle_info(%Loopyard.Events.DockerObserver.Changed{}, socket),
    do: {:noreply, reload(socket)}

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl Loopyard.Events.Projects.Subscriber
  def on_changed(_e, socket), do: {:noreply, reload(socket)}

  defp reload(socket), do: assign(socket, :projects, load_birdseye(socket.assigns.host))

  # The birdseye: every project → its workspaces → their agents, each carrying
  # LIVE status (via the shared normalizer, same as the sidebar + right pane) +
  # what the agent is doing right now + any openable ports. `host` builds the
  # port URLs from the same host the browser is on.
  defp load_birdseye(host) do
    agents_by_ws =
      Loopyard.ChatAgent.list_agents() |> Enum.group_by(&Map.get(&1, :workspace_id))

    ProjectRegistry.list_projects()
    |> Enum.map(fn project ->
      workspaces =
        project.id
        |> ProjectRegistry.list_workspaces()
        |> Enum.map(fn ws ->
          agents = agents_by_ws |> Map.get(ws.id, []) |> Enum.map(&enrich_agent/1)

          %{
            id: ws.id,
            name: ws[:name] || ws.id,
            agents: agents,
            ports: ws_ports(ws.id, host)
          }
        end)

      all_agents = Enum.flat_map(workspaces, & &1.agents)

      %{
        id: project.id,
        name: project.name,
        location: project_location(project),
        dot: aggregate_dot(all_agents),
        workspace_count: length(workspaces),
        agent_count: length(all_agents),
        working_count: Enum.count(all_agents, &(&1.display == :thinking)),
        workspaces: workspaces
      }
    end)
  end

  # One agent, decorated for the birdseye: display status (drives the dot), a
  # one-line "what it's doing right now", and cost so you can see spend at a
  # glance. Status goes through the ONE canonical normalizer so this never
  # disagrees with the sidebar or the agent's own page.
  defp enrich_agent(a) do
    display = LoopyardWeb.Components.Sidebar.agent_display_status(a)

    %{
      id: a.id,
      workspace_id: a.workspace_id,
      name: Map.get(a, :name) || "Agent",
      display: display,
      dot: LoopyardWeb.Components.Sidebar.status_dot(display),
      activity: activity_label(display, a),
      model: Map.get(a, :model),
      cost: Map.get(a, :total_cost_usd)
    }
  end

  # A plain-language "what's up with this agent" line.
  defp activity_label(:thinking, a) do
    case Map.get(a, :active_tool) do
      tool when is_binary(tool) and tool != "" -> tool
      _ -> "working…"
    end
  end

  defp activity_label(:ready, _a), do: "idle"
  defp activity_label(:crashed, _a), do: "needs attention"
  defp activity_label(:quarantined, _a), do: "quarantined"
  defp activity_label(_sleeping, _a), do: "asleep"

  # Exposed (network-open) ports for a workspace, as clickable targets. Only
  # exposed ports are openable from the browser, so those are the ones worth
  # surfacing on the birdseye.
  defp ws_ports(workspace_id, host) do
    Loopyard.PortRegistry.list_for_workspace(workspace_id)
    |> Enum.filter(& &1.exposed)
    |> Enum.map(fn p -> %{port: p.host_port, url: "http://#{host}:#{p.host_port}"} end)
    |> Enum.sort_by(& &1.port)
  rescue
    _ -> []
  end

  # Aggregate dot for a project (loudest DISPLAY state wins) — identical logic
  # to the sidebar so a project reads the same in both places.
  defp aggregate_dot([]), do: "bg-zinc-300 dark:bg-zinc-600"

  defp aggregate_dot(agents) do
    displays = Enum.map(agents, & &1.display)

    cond do
      Enum.any?(displays, &(&1 in [:crashed, :quarantined])) ->
        LoopyardWeb.Components.Sidebar.status_dot(:crashed)

      Enum.any?(displays, &(&1 == :thinking)) ->
        LoopyardWeb.Components.Sidebar.status_dot(:thinking)

      Enum.any?(displays, &(&1 == :ready)) ->
        LoopyardWeb.Components.Sidebar.status_dot(:ready)

      true ->
        LoopyardWeb.Components.Sidebar.status_dot(:sleeping)
    end
  end

  defp home_subtitle([]), do: "Nothing here yet — create your first project below."

  defp home_subtitle(projects) do
    n = length(projects)
    working = Enum.sum(Enum.map(projects, & &1.working_count))
    agents = Enum.sum(Enum.map(projects, & &1.agent_count))

    working_phrase =
      if working > 0,
        do: "#{working} working now",
        else: "#{agents} #{pluralize(agents, "agent")}"

    "#{n} #{pluralize(n, "project")} · #{working_phrase}"
  end

  defp pluralize(1, word), do: word
  defp pluralize(_, word), do: word <> "s"

  @impl true
  def render(assigns) do
    ~H"""
    <.page_shell
      breadcrumbs={crumbs(@live_action)}
      iex_session={@iex_session}
      max_width={:xl}
      flash={@flash}
    >
      <%= case @live_action do %>
        <% :index -> %>
          <%!-- The birdseye: every project → workspace → agent, expanded, with
               live status + what each agent is doing + openable ports. The big
               mission-control twin of the sidebar. --%>
          <header class="mb-8 flex items-end justify-between gap-4">
            <div>
              <h1 class="text-2xl font-semibold tracking-tight text-zinc-900 dark:text-zinc-50">
                Your projects
              </h1>
              <p class="text-sm text-zinc-500 dark:text-zinc-400 mt-1">
                {home_subtitle(@projects)}
              </p>
            </div>
            <.link
              navigate="/projects/new"
              class="hidden sm:inline-flex items-center gap-1.5 rounded-lg border border-zinc-200 dark:border-zinc-800 px-3 py-2 text-sm font-medium text-zinc-600 dark:text-zinc-300 hover:border-violet-300 dark:hover:border-violet-500/40 hover:text-violet-600 dark:hover:text-violet-400 transition-colors"
            >
              <svg viewBox="0 0 20 20" fill="currentColor" class="w-4 h-4"><path d="M10.75 4.75a.75.75 0 0 0-1.5 0v4.5h-4.5a.75.75 0 0 0 0 1.5h4.5v4.5a.75.75 0 0 0 1.5 0v-4.5h4.5a.75.75 0 0 0 0-1.5h-4.5v-4.5Z" /></svg>
              New project
            </.link>
          </header>

          <div class="space-y-5">
            <section
              :for={project <- @projects}
              class="rounded-2xl border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900/40 overflow-hidden"
            >
              <%!-- Project header: rollup dot + name + where it lives. --%>
              <.link
                navigate={"/projects/#{project.id}"}
                class="group flex items-center gap-3 px-5 py-3.5 border-b border-zinc-100 dark:border-zinc-800/70 hover:bg-zinc-50/70 dark:hover:bg-zinc-800/30 transition-colors"
              >
                <span class={["h-2.5 w-2.5 rounded-full flex-none", project.dot]} />
                <h2 class="text-base font-semibold text-zinc-900 dark:text-zinc-50 truncate">
                  {project.name}
                </h2>
                <span class="text-xs font-mono text-zinc-400 dark:text-zinc-500 truncate hidden md:block">
                  {project.location}
                </span>
                <span class="ml-auto text-xs text-zinc-400 dark:text-zinc-500 flex-none">
                  {project.workspace_count} {pluralize(project.workspace_count, "workspace")}
                </span>
              </.link>

              <%!-- Workspaces → agents. Each row is a live status line you click into. --%>
              <div class="divide-y divide-zinc-100 dark:divide-zinc-800/60">
                <div :for={ws <- project.workspaces} class="px-3 py-2">
                  <div class="flex items-center gap-2 px-2 pb-1">
                    <span class="text-xs font-semibold uppercase tracking-wide text-zinc-400 dark:text-zinc-500 truncate">
                      {ws.name}
                    </span>
                    <a
                      :for={p <- ws.ports}
                      href={p.url}
                      target="_blank"
                      rel="noopener"
                      class="inline-flex items-center gap-1 rounded-md bg-emerald-50 dark:bg-emerald-500/10 px-1.5 py-0.5 text-[11px] font-mono font-medium text-emerald-700 dark:text-emerald-400 hover:bg-emerald-100 dark:hover:bg-emerald-500/20 transition-colors"
                      title={"Open #{p.url}"}
                    >
                      :{p.port}
                      <svg viewBox="0 0 20 20" fill="currentColor" class="w-3 h-3"><path d="M11 3a1 1 0 1 0 0 2h2.586l-6.293 6.293a1 1 0 1 0 1.414 1.414L15 6.414V9a1 1 0 1 0 2 0V4a1 1 0 0 0-1-1h-5Z" /><path d="M5 5a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h8a2 2 0 0 0 2-2v-3a1 1 0 1 0-2 0v3H5V7h3a1 1 0 0 0 0-2H5Z" /></svg>
                    </a>
                    <.link
                      navigate={"/projects/#{project.id}/workspaces/#{ws.id}"}
                      class="ml-auto text-[11px] text-zinc-400 hover:text-violet-500 dark:hover:text-violet-400 flex-none"
                    >
                      open →
                    </.link>
                  </div>

                  <%!-- Agent rows: the actual "who's doing what" of the birdseye. --%>
                  <.link
                    :for={agent <- ws.agents}
                    navigate={"/projects/#{project.id}/workspaces/#{ws.id}/agents/#{agent.id}"}
                    class="group flex items-center gap-3 rounded-lg px-2 py-2 hover:bg-zinc-50 dark:hover:bg-zinc-800/40 transition-colors"
                  >
                    <span class={["h-2.5 w-2.5 rounded-full flex-none", agent.dot]} />
                    <span class="text-sm font-medium text-zinc-800 dark:text-zinc-100 flex-none">
                      {agent.name}
                    </span>
                    <span class="text-sm text-zinc-500 dark:text-zinc-400 truncate font-mono text-xs">
                      {agent.activity}
                    </span>
                    <span class="ml-auto flex items-center gap-3 flex-none text-xs text-zinc-400 dark:text-zinc-500">
                      <span :if={agent.model} class="font-mono hidden sm:inline">{agent.model}</span>
                      <span :if={agent.cost && agent.cost > 0} class="tabular-nums">
                        ${:erlang.float_to_binary(agent.cost * 1.0, decimals: 2)}
                      </span>
                    </span>
                  </.link>

                  <div
                    :if={ws.agents == []}
                    class="flex items-center gap-2 px-2 py-2 text-sm text-zinc-400 dark:text-zinc-500"
                  >
                    <span class="h-2.5 w-2.5 rounded-full flex-none bg-zinc-300 dark:bg-zinc-600" />
                    <span>no agent yet</span>
                    <.link
                      navigate={"/projects/#{project.id}/workspaces/#{ws.id}"}
                      class="text-violet-500 dark:text-violet-400 hover:underline"
                    >
                      start one →
                    </.link>
                  </div>
                </div>
              </div>
            </section>

            <div :if={@projects == []} class="text-sm text-zinc-400 py-8 text-center">
              No projects yet.
            </div>
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
