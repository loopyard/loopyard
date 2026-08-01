defmodule LoopyardWeb.ProjectListLive do
  use LoopyardWeb, :live_view
  use LoopyardWeb.IExAware

  alias Loopyard.ProjectRegistry
  alias LoopyardWeb.Components.ProjectList

  @impl true
  @behaviour Loopyard.Events.Projects.Subscriber
  @behaviour Loopyard.Events.ChangeCounts.Subscriber

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
        # Live ±N change badges on the workspace cards.
        Loopyard.Events.ChangeCounts.subscribe()
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
     |> assign(:projects, Loopyard.WorkspaceTree.global(host))
     |> assign(:launch_cmd, launch_cmd)
     |> assign(:creating, nil)
     |> assign(:github_url, "")
     |> assign(:workstation, safe_ws())
     |> assign(:github_connected?, github_token() != nil)}
  end

  # The workstation's GitHub token — what makes private clones work without a
  # second credential to manage. nil when GitHub hasn't been connected yet.
  defp github_token do
    keys = Loopyard.Workstation.Env.all(Loopyard.Workstation.current())

    Enum.find_value(["GITHUB_TOKEN", "GH_TOKEN"], fn k ->
      case Map.get(keys, k) do
        v when is_binary(v) and v != "" -> v
        _ -> nil
      end
    end)
  rescue
    _ -> nil
  end

  defp safe_ws do
    Loopyard.Workstation.current()
  rescue
    _ -> "default"
  end

  # Clone failures are mostly one of three human-fixable things; say which.
  defp clone_error(reason) do
    text = if is_binary(reason), do: reason, else: inspect(reason, limit: 20)

    cond do
      text =~ "Authentication" or text =~ "403" or text =~ "denied" ->
        "#{text} — if it's private, connect GitHub first."

      text =~ "not found" or text =~ "404" ->
        "#{text} — check the URL, or connect GitHub if it's private."

      true ->
        text
    end
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

  # Clone a git URL into its own volume. The engine already existed
  # (`ProjectRegistry.add_from_url/2`); only this form was missing, which left
  # the intended happy path — and the ONLY path that works when Loopyard runs
  # on a different machine than the developer — behind a "Soon" badge.
  #
  # Runs OFF the LiveView process: a clone is seconds of network + Docker work,
  # and freezing the UI through it is exactly the wrong feel. Same
  # `:creating` pattern as create_project.
  @impl true
  def handle_event("add_from_url", %{"url" => url} = params, socket) do
    url = String.trim(url)
    branch = params |> Map.get("branch", "") |> String.trim()

    cond do
      url == "" ->
        {:noreply, put_flash(socket, :error, "Paste a repo URL")}

      socket.assigns.creating ->
        {:noreply, socket}

      true ->
        lv = self()
        token = github_token()

        Task.Supervisor.start_child(Loopyard.TaskSupervisor, fn ->
          # Resolve the branch OFF the happy path of guessing. Defaulting to
          # "main" fails outright on any repo that still uses master (or
          # trunk, or develop) — github.com/octocat/Hello-World is master, and
          # the user gets "Remote branch main not found" for a URL that is
          # perfectly valid. Nobody should have to know a repo's default
          # branch to clone it.
          resolved =
            if branch == "",
              do: Loopyard.Git.default_branch(url, token) || "main",
              else: branch

          send(
            lv,
            {:cloned, Loopyard.ProjectRegistry.add_from_url(url, branch: resolved, token: token)}
          )
        end)

        {:noreply, socket |> assign(:creating, url) |> assign(:github_url, url)}
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

  # add_from_url/2 returns the project only — resolve its workspace to land the
  # user in the workspace they just cloned, not a project index.
  def handle_info({:cloned, {:ok, project, workspace}}, socket) do
    {:noreply, push_navigate(socket, to: "/projects/#{project.id}/workspaces/#{workspace.id}")}
  end

  def handle_info({:cloned, {:ok, project}}, socket) do
    {:noreply, push_navigate(socket, to: "/projects/#{project.id}")}
  end

  def handle_info({:cloned, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:creating, nil)
     |> put_flash(:error, "Couldn't clone that repo: #{clone_error(reason)}")}
  end

  def handle_info(%Loopyard.Events.Projects.Changed{} = e, socket), do: on_changed(e, socket)

  # Only STATUS changes refresh the birdseye — not every tool call. Reloading on
  # each tool call rebuilt the whole page constantly and made it flicker; the
  # home dots only track status anyway.
  def handle_info(%Loopyard.Events.Activity.Event{kind: :status}, socket),
    do: {:noreply, reload(socket)}

  def handle_info(%Loopyard.Events.Activity.Event{}, socket), do: {:noreply, socket}

  # Container/port state changed → refresh so the openable :port chips are current.
  def handle_info(%Loopyard.Events.DockerObserver.Changed{}, socket),
    do: {:noreply, reload(socket)}

  def handle_info(%Loopyard.Events.ChangeCounts.Updated{} = e, socket),
    do: on_change_counts_updated(e, socket)

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl Loopyard.Events.Projects.Subscriber
  def on_changed(_e, socket), do: {:noreply, reload(socket)}

  @impl Loopyard.Events.ChangeCounts.Subscriber
  def on_change_counts_updated(_e, socket), do: {:noreply, reload(socket)}

  defp reload(socket),
    do: assign(socket, :projects, Loopyard.WorkspaceTree.global(socket.assigns.host))

  # All agents under a project, across its workspaces — for rollup dot + counts.
  defp project_agents(project), do: Enum.flat_map(project.workspaces, & &1.agents)

  defp home_subtitle([]), do: "Nothing here yet — create your first project below."

  defp home_subtitle(projects) do
    n = length(projects)
    agents = projects |> Enum.flat_map(&project_agents/1)

    # Count from raw :status (no per-agent Registry lookup) — same source as the dots.
    working = Enum.count(agents, &(Map.get(&1, :status) in [:thinking, :compacting, :booting]))

    working_phrase =
      if working > 0,
        do: "#{working} working now",
        else: "#{length(agents)} #{pluralize(length(agents), "agent")}"

    "#{n} #{pluralize(n, "project")} · #{working_phrase}"
  end

  defp pluralize(1, word), do: word
  defp pluralize(_, word), do: word <> "s"

  @impl true
  def render(assigns) do
    ~H"""
    <.page_shell
      mode={:workspaces}
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
            <p class="text-sm text-zinc-500 dark:text-zinc-400">
              {home_subtitle(@projects)}
            </p>
            <.link
              navigate="/projects/new"
              class="hidden sm:inline-flex items-center gap-1.5 rounded-sm border border-zinc-200 dark:border-zinc-800 px-3 py-2 text-sm font-medium text-zinc-600 dark:text-zinc-300 hover:border-violet-300 dark:hover:border-violet-500/40 hover:text-violet-600 dark:hover:text-violet-400 transition-colors"
            >
              <svg viewBox="0 0 20 20" fill="currentColor" class="w-4 h-4"><path d="M10.75 4.75a.75.75 0 0 0-1.5 0v4.5h-4.5a.75.75 0 0 0 0 1.5h4.5v4.5a.75.75 0 0 0 1.5 0v-4.5h4.5a.75.75 0 0 0 0-1.5h-4.5v-4.5Z" /></svg>
              New project
            </.link>
          </header>

          <%!-- The ONE grouped project → workspace list (also loaded by the mobile
    switcher, so there's a single visual language). --%>
          <ProjectList.project_groups projects={@projects} />
          <div class="mt-6 sm:hidden">
            <.link
              navigate="/projects/new"
              class="flex items-center justify-center gap-1.5 w-full  border border-dashed border-zinc-300 dark:border-zinc-700 px-3 py-3 text-sm font-medium text-zinc-500 dark:text-zinc-400 active:bg-zinc-100 dark:active:bg-zinc-800 transition-colors"
            >
              <svg viewBox="0 0 20 20" fill="currentColor" class="w-4 h-4"><path d="M10.75 4.75a.75.75 0 0 0-1.5 0v4.5h-4.5a.75.75 0 0 0 0 1.5h4.5v4.5a.75.75 0 0 0 1.5 0v-4.5h4.5a.75.75 0 0 0 0-1.5h-4.5v-4.5Z" /></svg>
              New project
            </.link>
          </div>
        <% :new -> %>
          <div class="max-w-2xl">
            <h1 class="text-xl font-semibold mb-1">New project</h1>
            <p class="text-sm text-zinc-500 dark:text-zinc-400 mb-5">How do you want to start?</p>
            <div class="space-y-2.5">
              <.method_card
                navigate="/projects/new/github"
                title="From GitHub"
                desc="Clone a repo — works from anywhere, including a phone."
              />
              <.method_card
                navigate="/projects/new/scratch"
                title="From scratch"
                desc="Name it and start building — a fresh repo, ready instantly."
              />
              <.method_card
                navigate="/projects/new/folder"
                title="From a folder on the Loopyard machine"
                desc="Code already on the disk where Loopyard itself is running."
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
                class="w-full rounded-sm border border-zinc-300 dark:border-zinc-600 bg-brand-paper dark:bg-brand-ink px-3 py-2.5 text-sm
    text-zinc-900 dark:text-zinc-200 placeholder:text-zinc-400 dark:placeholder:text-zinc-600 disabled:opacity-60
    focus:outline-none focus:ring-1 focus:ring-violet-500/30 focus:border-violet-400"
              />
              <button
                type="submit"
                disabled={@creating != nil}
                class="focus-ring w-full inline-flex items-center justify-center gap-1.5 rounded-sm bg-violet-600 hover:bg-violet-700 disabled:opacity-70 px-5 py-2.5 text-sm font-semibold text-white transition-colors"
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
                class="flex-1 min-w-0 rounded-sm border border-zinc-300 dark:border-zinc-600 bg-brand-paper dark:bg-brand-ink px-3 py-2.5 text-sm font-mono
    text-zinc-900 dark:text-zinc-300 placeholder:text-zinc-400 dark:placeholder:text-zinc-600
    focus:outline-none focus:ring-1 focus:ring-violet-500/20 focus:border-violet-400"
              />
              <button
                type="submit"
                class="focus-ring flex-none rounded-sm bg-zinc-900 dark:bg-zinc-200 hover:bg-zinc-800 dark:hover:bg-white px-5 py-2.5 text-sm font-semibold text-white dark:text-zinc-900 transition-colors"
              >
                Open
              </button>
            </form>
            <div class=" border border-zinc-200 dark:border-zinc-700 bg-zinc-50 dark:bg-zinc-800/50 p-4">
              <p class="text-xs text-zinc-500 dark:text-zinc-400 mb-1.5">
                Or run this from that folder in your terminal:
              </p>
              <div class="flex items-center gap-2">
                <div class="flex-1 min-w-0 bg-zinc-900 dark:bg-zinc-950 rounded-sm px-3 py-1.5 font-mono text-xs text-zinc-300 overflow-x-auto whitespace-nowrap select-all">
                  <span class="text-zinc-500 select-none">$ </span>{@launch_cmd}
                </div>
                <button
                  id="copy-launch"
                  phx-hook="CopySource"
                  data-source={@launch_cmd}
                  class="flex-none rounded-sm border border-zinc-300 dark:border-zinc-600 hover:bg-zinc-100 dark:hover:bg-zinc-700 px-3 py-1.5 text-xs font-medium text-zinc-600 dark:text-zinc-300 transition-colors"
                >
                  Copy
                </button>
              </div>
            </div>
          </div>
        <% :new_github -> %>
          <div class="max-w-2xl">
            <h1 class="text-xl font-semibold mb-1">From GitHub</h1>
            <p class="text-sm text-zinc-500 dark:text-zinc-400 mb-5">
              Clone a repo into its own workspace. This is the only route that works when
              Loopyard runs on a different machine than the one you're sitting at.
            </p>

            <form phx-submit="add_from_url" class="mb-5">
              <div class="flex flex-col sm:flex-row sm:items-center gap-2">
                <input
                  type="text"
                  name="url"
                  value={@github_url}
                  placeholder="https://github.com/owner/repo"
                  autocomplete="off"
                  autofocus
                  disabled={@creating != nil}
                  class="flex-1 min-w-0 rounded-sm border border-zinc-300 dark:border-zinc-600 bg-brand-paper dark:bg-brand-ink px-3 py-3 md:py-2.5 text-sm font-mono
    text-zinc-900 dark:text-zinc-300 placeholder:text-zinc-400 dark:placeholder:text-zinc-600
    focus:outline-none focus:ring-1 focus:ring-violet-500/20 focus:border-violet-400 disabled:opacity-60"
                />
                <input
                  type="text"
                  name="branch"
                  value=""
                  placeholder="branch (optional)"
                  aria-label="Branch — blank uses the repo default"
                  disabled={@creating != nil}
                  class="sm:w-32 flex-none rounded-sm border border-zinc-300 dark:border-zinc-600 bg-brand-paper dark:bg-brand-ink px-3 py-3 md:py-2.5 text-sm font-mono
    text-zinc-900 dark:text-zinc-300 focus:outline-none focus:ring-1 focus:ring-violet-500/20 focus:border-violet-400 disabled:opacity-60"
                />
                <button
                  type="submit"
                  disabled={@creating != nil}
                  class="focus-ring flex-none rounded-sm bg-zinc-900 dark:bg-zinc-200 hover:bg-zinc-800 dark:hover:bg-white px-5 py-3 md:py-2.5 text-sm font-semibold text-white dark:text-zinc-900 transition-colors disabled:opacity-60"
                >
                  {if @creating, do: "Cloning…", else: "Clone"}
                </button>
              </div>
            </form>

            <%!-- Private repos need a token, and the fix is one click away rather
                 than a dead end. Connected → say so quietly and move on. --%>
            <div
              :if={not @github_connected?}
              class="border border-zinc-200 dark:border-zinc-700 bg-zinc-50 dark:bg-zinc-800/50 p-4"
            >
              <p class="text-sm text-zinc-700 dark:text-zinc-300">
                Public repos clone as-is. For private ones,
                <.link
                  navigate={"/workstations/#{@workstation}/github"}
                  class="underline hover:text-zinc-900 dark:hover:text-zinc-100"
                >connect GitHub</.link>
                — one command on your Mac, and the token is reused here automatically.
              </p>
            </div>
            <p
              :if={@github_connected?}
              class="text-xs text-zinc-500 dark:text-zinc-400"
            >
              GitHub is connected — private repos work too.
            </p>
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
      class="flex items-center justify-between gap-3 w-full  border border-zinc-200 dark:border-zinc-700 p-4 hover:border-violet-400 dark:hover:border-violet-500 hover:bg-zinc-50 dark:hover:bg-zinc-800/50 transition-colors group"
    >
      <div class="min-w-0">
        <div class="flex items-center gap-2">
          <span class="text-sm font-semibold">{@title}</span>
          <span
            :if={@badge}
            class="section-label rounded-full bg-zinc-200 dark:bg-zinc-700 px-1.5 py-0.5"
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

  defp crumbs(:index), do: [{"Loopyard", "/"}, {"Workspaces", nil}]
  defp crumbs(:new), do: [{"Loopyard", "/"}, {"Workspaces", "/workspaces"}, {"New project", nil}]

  defp crumbs(:new_scratch),
    do: [{"Loopyard", "/"}, {"New project", "/projects/new"}, {"From scratch", nil}]

  defp crumbs(:new_folder),
    do: [{"Loopyard", "/"}, {"New project", "/projects/new"}, {"Folder", nil}]

  defp crumbs(:new_github),
    do: [{"Loopyard", "/"}, {"New project", "/projects/new"}, {"GitHub", nil}]

  defp crumbs(_), do: [{"Loopyard", nil}]
end
