defmodule LoopyardWeb.WorkstationLive do
  @moduledoc """
  The **Workstation** page — your *identity*: a home folder of credentials that
  every agent you spin up inherits.

  Two surfaces:

  * **Console** — a shell on the live workstation container (which mounts your
  `$HOME` volume), for the logins only you can do (`gh auth login`,
  `claude login`, `fly auth login`). They persist in the home volume; every
  agent inherits them.
  * **Environment** — transfer creds from your Mac, set env vars (delivered as
  files in the home volume, sourced by a login shell — never `docker -e`),
  push tokens.

  Identity is the home volume, not an image: the bench + console boot from the
  shared base image, and your creds ride in via the mounted `$HOME`. See
  plans/agent-home-and-refresh.md.
  """
  use LoopyardWeb, :live_view
  use LoopyardWeb.IExAware

  import LoopyardWeb.Components.Workstation

  alias Loopyard.Terminal
  alias Loopyard.Workstation.{Container, Env, Integration}

  @impl true
  def mount(%{"id" => ws}, _session, socket) do
    if Loopyard.Workstation.exists?(ws) do
      mount_workstation(ws, socket)
    else
      {:ok,
       socket
       |> put_flash(:error, "No workstation \"#{ws}\".")
       |> push_navigate(to: "/workstations/#{Loopyard.Workstation.current()}")}
    end
  end

  # Bare /workstations — the list, where you see all identities + create one.
  # Switching/creating lives HERE, not on a single workstation's page.
  def mount(_params, _session, socket) do
    socket =
      if connected?(socket),
        do: subscribe_iex(socket),
        else: assign(socket, :iex_session, %{level: nil})

    {:ok,
     socket
     |> assign(:workstation_ids, Loopyard.Workstation.list())
     |> assign(:current_id, Loopyard.Workstation.current())}
  end

  # The page operates on the workstation in the URL. Visiting it makes it the
  # identity you're operating as (what new agents inherit).
  defp mount_workstation(ws, socket) do
    _ = Loopyard.Workstation.set_current(ws)

    socket =
      if connected?(socket) do
        subscribe_iex(socket)
      else
        assign(socket, :iex_session, %{level: nil})
      end

    socket =
      socket
      |> assign(:current_id, ws)
      |> assign(:workstation_ids, Loopyard.Workstation.list())
      |> assign(:console_container, nil)
      |> assign(:console_error, nil)
      |> assign(:term_nonce, 0)
      |> assign(:restarting, false)
      |> assign(:push_token, Loopyard.PushToken.get())
      |> assign(:integrations, Integration.all())
      |> assign(:integration_status, Map.new(Integration.all(), &{&1.id, :checking}))
      |> assign_env()

    # Boot only what THIS page uses (off the LV process — these block on
    # container create). The calm hub no longer spins up the console on every
    # view/reconnect.
    socket =
      if connected?(socket),
        do: boot_for_action(socket, socket.assigns.live_action, ws),
        else: socket

    {:ok, socket}
  end

  # Console page: just the shell.
  defp boot_for_action(socket, :console, ws),
    do: start_async(socket, :ensure_console, fn -> Container.ensure_up(ws) end)

  # Hub: only the integration status probes (each execs into the container).
  defp boot_for_action(socket, :show, _ws), do: check_integrations(socket)

  # Env (and anything else): nothing to boot.
  defp boot_for_action(socket, _action, _ws), do: socket

  defp check_integrations(socket) do
    ws = socket.assigns.current_id

    Enum.reduce(socket.assigns.integrations, socket, fn ig, s ->
      start_async(s, {:int_status, ig.id}, fn -> Integration.connected?(ig, ws) end)
    end)
  end

  # --- async boots ---

  @impl true
  def handle_async(:ensure_console, {:ok, {:ok, name}}, socket),
    do: {:noreply, assign(socket, :console_container, name)}

  def handle_async(:ensure_console, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, :console_error, inspect(reason))}

  def handle_async(:ensure_console, {:exit, reason}, socket),
    do: {:noreply, assign(socket, :console_error, inspect(reason))}

  def handle_async({:int_status, id}, {:ok, connected?}, socket) do
    state = if connected?, do: :connected, else: :not_connected
    {:noreply, update(socket, :integration_status, &Map.put(&1, id, state))}
  end

  def handle_async({:int_status, id}, {:exit, _}, socket),
    do: {:noreply, update(socket, :integration_status, &Map.put(&1, id, :not_connected))}

  def handle_async(:restart_machine, {:ok, {:ok, name}}, socket) do
    # Bump the nonce so the terminal hook remounts and reconnects to the fresh
    # container instead of clinging to the dead exec.
    {:noreply,
     socket
     |> assign(:restarting, false)
     |> assign(:console_container, name)
     |> assign(:term_nonce, socket.assigns.term_nonce + 1)}
  end

  def handle_async(:restart_machine, {:ok, {:error, reason}}, socket),
    do:
      {:noreply, socket |> assign(:restarting, false) |> assign(:console_error, inspect(reason))}

  def handle_async(:restart_machine, {:exit, reason}, socket),
    do:
      {:noreply, socket |> assign(:restarting, false) |> assign(:console_error, inspect(reason))}

  # --- events ---

  @impl true
  def handle_event("add_env", %{"name" => name, "value" => value}, socket) do
    case Env.put(name, value, socket.assigns.current_id) do
      :ok ->
        {:noreply,
         socket
         |> assign_env()
         |> put_flash(:info, "Saved #{String.trim(name)} — Restart the machine to apply.")}

      {:error, :invalid_key} ->
        {:noreply, put_flash(socket, :error, "Invalid env var name (use A–Z, 0–9, _).")}
    end
  end

  def handle_event("delete_env", %{"key" => key}, socket) do
    Env.delete(key, socket.assigns.current_id)

    {:noreply,
     socket
     |> assign_env()
     |> put_flash(:info, "Removed #{key} — Restart the machine to apply.")}
  end

  def handle_event("restart_machine", _params, socket) do
    # Recreate the workstation container from scratch — for when the shell wedges.
    # Kill the terminal session first so a fresh `docker exec` lands on the new
    # container; the $HOME volume (logins/dotfiles) is untouched.
    ws = socket.assigns.current_id

    socket =
      socket
      |> assign(:restarting, true)
      |> assign(:console_container, nil)
      |> start_async(:restart_machine, fn ->
        Terminal.stop(Container.name(ws))
        Container.down(ws)
        Container.ensure_up(ws)
      end)

    {:noreply, socket}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- helpers ---

  defp assign_env(socket) do
    keys = Env.keys(socket.assigns.current_id)
    integration_keys = Enum.map(Env.integrations(), & &1.key)

    socket
    |> assign(:env_keys, keys)
    |> assign(:other_env_keys, keys -- integration_keys)
  end

  @impl true
  def render(%{live_action: :index} = assigns), do: index_page(assigns)
  def render(%{live_action: :console} = assigns), do: console_page(assigns)
  def render(%{live_action: :env} = assigns), do: env_page(assigns)
  def render(assigns), do: hub_page(assigns)

  # --- Index: all workstations + create one. ---
  defp index_page(assigns) do
    ~H"""
    <.page_shell
      breadcrumbs={[{"Workstations", nil}]}
      iex_session={@iex_session}
      max_width={:md}
      flash={@flash}
    >
      <div class="space-y-8">
        <div class="space-y-1">
          <h1 class="text-xl font-semibold tracking-tight">Workstations</h1>
          <p class="text-sm text-zinc-500 dark:text-zinc-400">
            An identity is a home folder of credentials — every agent you spin up inherits it.
          </p>
        </div>

        <.section title="Your workstations">
          <.nav_list>
            <.nav_row
              :for={id <- @workstation_ids}
              navigate={"/workstations/#{id}"}
              title={id}
              desc={
                if id == @current_id,
                  do: "The identity you're operating as.",
                  else: "Open to switch to it."
              }
            >
              <:trailing :if={id == @current_id}>
                <span class="inline-flex items-center gap-1.5 text-[11px] text-sky-600 dark:text-sky-400">
                  <span class="w-1.5 h-1.5 rounded-full bg-sky-500"></span> current
                </span>
              </:trailing>
            </.nav_row>
          </.nav_list>
        </.section>

        <.section
          title="New workstation"
          hint="A fresh identity — connect its own tools, set up its own creds."
        >
          <form action="/workstations/create" method="post" class="flex items-center gap-2">
            <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
            <input
              type="text"
              name="ws_id"
              placeholder="new-id"
              pattern="[a-z0-9][a-z0-9-]*"
              title="Lowercase letters, digits, dashes"
              class="flex-1 rounded-sm border border-zinc-300 dark:border-zinc-600 bg-white dark:bg-zinc-800 px-3 py-2 text-sm placeholder:text-zinc-400 focus-ring"
            />
            <.button variant={:primary} type="submit" class="flex-none">Create</.button>
          </form>
        </.section>
      </div>
    </.page_shell>
    """
  end

  # The hub: who you are, the services to connect, and links to the rest.
  defp hub_page(assigns) do
    ~H"""
    <.page_shell
      breadcrumbs={[{"Workstations", "/workstations"}, {@current_id, nil}]}
      iex_session={@iex_session}
      max_width={:md}
      flash={@flash}
    >
      <div id="ws-page" phx-hook="WsScroll" class="space-y-8">
        <div class="flex items-baseline gap-3">
          <h1 class="text-xl font-semibold tracking-tight">{@current_id}</h1>
          <.link
            navigate="/workstations"
            class="text-xs text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-300"
          >
            All workstations
          </.link>
        </div>

        <.section
          title="Connect your tools"
          hint="Click in to connect — the default on each is one command you run on your Mac."
        >
          <.nav_list>
            <.nav_row
              :for={ig <- @integrations}
              navigate={"/workstations/#{@current_id}/#{ig.id}"}
              title={ig.label}
              desc={ig.blurb}
            >
              <:trailing><.status_pill status={@integration_status[ig.id]} /></:trailing>
            </.nav_row>
          </.nav_list>
        </.section>

        <.section title="Configure">
          <.nav_list>
            <.nav_row
              navigate={"/workstations/#{@current_id}/console"}
              title="Console"
              desc="A shell on the workstation — log in to your tools, poke around."
            />
            <.nav_row
              navigate={"/workstations/#{@current_id}/env"}
              title="Environment"
              desc="Transfer creds from your Mac, set env vars, push tokens."
            />
          </.nav_list>
        </.section>
      </div>
    </.page_shell>
    """
  end

  # --- Console page: a shell on the workstation. ---
  defp console_page(assigns) do
    ~H"""
    <.page_shell
      breadcrumbs={[
        {"Workstations", "/workstations"},
        {@current_id, "/workstations/#{@current_id}"},
        {"Console", nil}
      ]}
      iex_session={@iex_session}
      max_width={:xl}
      flash={@flash}
    >
      <div id="ws-page" phx-hook="WsScroll" class="space-y-3">
        <div class="flex items-center justify-between gap-3">
          <p class="text-sm text-zinc-500 dark:text-zinc-400">
            A shell on <span class="font-medium text-zinc-700 dark:text-zinc-200">{@current_id}</span>
            — logins persist in $HOME.
          </p>
          <.restart_button restarting={@restarting} />
        </div>
        <div
          id="ws-console"
          class="h-[72dvh]  border border-zinc-200 dark:border-zinc-700 overflow-hidden p-2 bg-[#18181b]"
        >
          <div
            :if={@console_container}
            id={"terminal-#{@console_container}-#{@term_nonce}"}
            phx-hook="Terminal"
            data-container={@console_container}
            phx-update="ignore"
            class="h-full overflow-hidden"
          >
          </div>
          <div
            :if={!@console_container && !@console_error}
            class="h-full flex items-center justify-center text-sm text-zinc-500"
          >
            <span class="inline-flex items-center gap-2">
              <.spinner /> {if @restarting,
                do: "Restarting the machine…",
                else: "Starting your console…"}
            </span>
          </div>
          <div
            :if={@console_error}
            class="rounded-sm border border-red-300 dark:border-red-800 bg-red-50 dark:bg-red-950/30 p-3 text-sm text-red-600 dark:text-red-400"
          >
            Couldn't start the workstation console: {@console_error}
          </div>
        </div>
      </div>
    </.page_shell>
    """
  end

  # --- Environment page: transfer creds, set env vars, push tokens. ---
  defp env_page(assigns) do
    ~H"""
    <.page_shell
      breadcrumbs={[
        {"Workstations", "/workstations"},
        {@current_id, "/workstations/#{@current_id}"},
        {"Environment", nil}
      ]}
      iex_session={@iex_session}
      max_width={:md}
      flash={@flash}
    >
      <div id="ws-page" phx-hook="WsScroll" class="space-y-8">
        <.section
          title="Transfer everything from your Mac"
          hint="One command, run where you're logged in — grabs your gh / fly / claude / codex creds and pipes them up. Files apply live; tokens need a Restart."
        >
          <.command_box
            id="clip-setup"
            command={"curl -fsS __ORIGIN__/workstations/#{@current_id}/setup.sh | sh"}
          />
        </.section>

        <.section
          title="Environment variables"
          hint="Delivered as files in the home volume, sourced by a login shell. Restart to apply."
        >
          <form phx-submit="add_env" class="flex flex-col sm:flex-row gap-2">
            <input
              name="name"
              placeholder="NAME"
              autocomplete="off"
              autocapitalize="characters"
              spellcheck="false"
              class="sm:w-56 font-mono text-sm rounded-sm border border-zinc-300 dark:border-zinc-600 bg-white dark:bg-zinc-800 px-3 py-2 text-zinc-900 dark:text-zinc-100 placeholder:text-zinc-400 focus:outline-none focus:ring-2 focus:ring-violet-500/20 focus:border-violet-400"
            />
            <input
              name="value"
              type="password"
              placeholder="value"
              autocomplete="off"
              spellcheck="false"
              class="flex-1 font-mono text-sm rounded-sm border border-zinc-300 dark:border-zinc-600 bg-white dark:bg-zinc-800 px-3 py-2 text-zinc-900 dark:text-zinc-100 placeholder:text-zinc-400 focus:outline-none focus:ring-2 focus:ring-violet-500/20 focus:border-violet-400"
            />
            <.button variant={:secondary} type="submit" class="flex-none">Add</.button>
          </form>
          <ul
            :if={@other_env_keys != []}
            class="divide-y divide-zinc-100 dark:divide-zinc-800 rounded-sm border border-zinc-200 dark:border-zinc-800 px-3"
          >
            <li :for={k <- @other_env_keys} class="flex items-center gap-3 py-2">
              <span class="font-mono text-sm text-zinc-700 dark:text-zinc-300">{k}</span>
              <span class="font-mono text-xs text-zinc-500 dark:text-zinc-400 select-none">
                ••••••••
              </span>
              <button
                phx-click="delete_env"
                phx-value-key={k}
                data-confirm={"Remove #{k}?"}
                class="ml-auto text-xs text-zinc-400 hover:text-red-500 transition-colors"
              >
                Remove
              </button>
            </li>
          </ul>
        </.section>

        <.section
          title="Push a single credential"
          hint="Each tool's page has the easy path. For a custom key or a remote Loopyard, this is the general form (carries your push token):"
        >
          <div id="ws-push" phx-hook="PushCmd" data-token={@push_token} class="relative">
            <pre class="overflow-x-auto rounded-sm bg-zinc-900 dark:bg-zinc-950 text-zinc-100 text-[11px] leading-relaxed font-mono p-3 pr-16 ring-1 ring-zinc-800"><code class="ws-push-cmd">{push_cmd(@push_token, @current_id)}</code></pre>
            <button
              type="button"
              class="ws-push-copy focus-ring absolute top-2 right-2 rounded-sm bg-zinc-800 hover:bg-zinc-700 text-zinc-200 px-2 py-1 text-[11px]"
            >
              Copy
            </button>
          </div>
          <p class="text-[11px] text-zinc-500 dark:text-zinc-400">
            Swap GITHUB_TOKEN for any key. On this machine you can drop the token entirely. Restart to apply — keep this command secret.
          </p>
        </.section>
      </div>
    </.page_shell>
    """
  end

  # Flush-left so the rendered <pre> shows the bare command. The trailing
  # backslashes are literal shell line-continuations (escaped here as \\).
  defp push_cmd(token, current_id) do
    """
    gh auth token | curl -fsS -T - \\
    -H "Authorization: Bearer #{token}" \\
    __ORIGIN__/workstations/#{current_id}/env/GITHUB_TOKEN\
    """
  end

  defp spinner(assigns) do
    ~H"""
    <svg
      class="w-3.5 h-3.5 animate-spin"
      xmlns="http://www.w3.org/2000/svg"
      fill="none"
      viewBox="0 0 24 24"
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
    """
  end
end
