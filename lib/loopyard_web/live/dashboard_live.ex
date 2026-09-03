defmodule LoopyardWeb.DashboardLive do
  @moduledoc """
  The homepage (`/`): a read-only status dashboard. One card per area of the
  system — Workspaces, Remote, System, Operated — each showing a live status
  summary and navigating into that area. This is what the old mobile overflow
  menu became.

  Live-updating two ways: it subscribes to global agent Activity (so the
  Workspaces card reacts the instant an agent changes state) and runs a short
  refresh tick for the areas that have no PubSub of their own (remote exposure,
  system health, operated-as). Everything routes through `refresh/1`.
  """
  use LoopyardWeb, :live_view
  use LoopyardWeb.IExAware

  import LoopyardWeb.Components.Common, only: [page_shell: 1]

  @refresh_ms 3_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      if connected?(socket) do
        Loopyard.Events.Notifications.subscribe()
        Loopyard.Events.Activity.subscribe_global()
        Process.send_after(self(), :refresh, @refresh_ms)
        subscribe_iex(socket)
      else
        assign(socket, :iex_session, %{level: nil})
      end

    host =
      case socket.host_uri do
        %URI{host: h} when is_binary(h) and h != "" -> h
        _ -> "localhost"
      end

    {:ok, socket |> assign(:host, host) |> refresh()}
  end

  # A turn finished / started / an agent errored → the Workspaces card changes.
  @impl true
  def handle_info(%Loopyard.Events.Activity.Event{kind: :status}, socket),
    do: {:noreply, refresh(socket)}

  def handle_info(%Loopyard.Events.Activity.Event{}, socket), do: {:noreply, socket}

  # The inbox changed → the Operator card's list and count.
  def handle_info(%Loopyard.Events.Notifications.Added{}, socket),
    do: {:noreply, socket |> refresh() |> load_attention_async()}

  def handle_info(%Loopyard.Events.Notifications.Changed{}, socket),
    do: {:noreply, socket |> refresh() |> load_attention_async()}

  # The heartbeat: refresh remote / system / operated (no PubSub) and reschedule.
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, refresh(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Recompute every card's snapshot. Each getter is crash-safe so one wedged
  # subsystem can't blank the whole dashboard.
  defp refresh(socket) do
    socket
    |> assign(:tree, safe(fn -> Loopyard.WorkspaceTree.global(socket.assigns.host) end, []))
    |> assign(:health, safe(&Loopyard.Health.severity/0, :unknown))
    |> assign(:remote_exposed, safe(&Loopyard.Bind.exposed?/0, false))
    |> assign(:bind, safe(&Loopyard.Bind.describe/0, "unknown"))
    |> assign(:workstation, safe(&Loopyard.Workstation.current/0, "—"))
    |> assign(
      :agent_rows,
      safe(fn -> LoopyardWeb.AgentsLive.Row.rows(Loopyard.Agents.summaries()) end, [])
    )
    |> then(
      &assign(
        &1,
        :agents_working,
        LoopyardWeb.AgentsLive.Row.working_count(&1.assigns.agent_rows)
      )
    )
    |> assign(:operator_count, safe(fn -> length(Loopyard.Workstation.list()) end, 1))
    |> load_attention_async()
    |> assign(:inference_ready?, safe(&inference_ready?/0, true))
    |> assign(:digest, safe(&finished_items/0, []))
    |> assign(:health_map, safe(&Loopyard.Health.overall/0, %{}))
    |> assign(:connections, safe(fn -> connections(socket.assigns.host) end, []))
    |> assign(:ports, safe(&port_rows/0, []))
    |> assign(:secret_count, safe(fn -> length(Loopyard.Secrets.list()) end, 0))
    |> then(&assign(&1, :first_run_step, first_run_step(&1.assigns)))
  end

  # Kick the attention load off the render path. Keeps whatever it already had
  # while reloading, so the heartbeat never blanks a card you're reading — only
  # the very first load shows the checking state.
  defp load_attention_async(socket) do
    host = socket.assigns.host

    socket
    |> assign_new(:attention, fn -> [] end)
    |> assign_new(:waiting, fn -> 0 end)
    |> assign_new(:attention_loaded?, fn -> false end)
    |> start_async(:attention, fn -> Loopyard.Attention.line(host) end)
  end

  @impl true
  def handle_async(:attention, {:ok, items}, socket) when is_list(items) do
    {:noreply,
     socket
     |> assign(:attention, items)
     |> assign(:waiting, length(items))
     |> assign(:attention_loaded?, true)
     |> then(&assign(&1, :first_run_step, first_run_step(&1.assigns)))}
  end

  # A failed or crashed lookup must not wedge the card in "checking" forever —
  # mark it loaded and show what we know (nothing waiting).
  def handle_async(:attention, _other, socket) do
    {:noreply, assign(socket, :attention_loaded?, true)}
  end

  # Which step of getting started is the user actually on? nil once they're
  # past it — a working install must not keep coaching.
  #
  # The ORDER is the point: inference first, because the agent is what builds
  # everything downstream, then a project to point it at. Each step names the
  # next one so the entrance is never a dead end.
  defp first_run_step(%{inference_ready?: false}), do: :inference

  defp first_run_step(%{tree: tree}) do
    if Enum.empty?(tree), do: :project
  end

  defp first_run_step(_), do: nil

  # Can an agent actually run? Without a credential the harness can't
  # authenticate, so EVERY downstream step (build the workspace, write the
  # compose file, boot the dev server) fails — the product is inert. Either
  # credential counts: the durable 1-year OAuth token or a raw API key.
  #
  # Defaults to TRUE on error (see `safe/2` above): a wedged env store must not
  # nag a working install to re-authenticate.
  defp inference_ready? do
    keys = Loopyard.Workstation.Env.keys(Loopyard.Workstation.current())
    "CLAUDE_CODE_OAUTH_TOKEN" in keys or "ANTHROPIC_API_KEY" in keys
  end

  # "All 3 subsystems healthy" is true of the SUBSYSTEMS and a lie about the
  # PRODUCT when there's no credential — the same screen was telling a new user
  # everything is fine directly under a band saying nothing can start. Two
  # elements contradicting each other is worse than either being wrong alone,
  # because now nothing on the page can be trusted. While a blocking first-run
  # step is open, say what's actually true.
  defp system_line(_health, :inference),
    do: "Subsystems up · agents blocked until Claude connects"

  defp system_line(health, _step), do: health_line(health)

  # Health.component/1 returns :healthy | {:degraded, reason} | {:down, reason}.
  defp health_word(:healthy), do: "ok"
  defp health_word({:degraded, _}), do: "degraded"
  defp health_word({:down, _}), do: "down"
  defp health_word(other), do: to_string(other)

  defp safe(fun, default) do
    fun.()
  rescue
    _ -> default
  catch
    _, _ -> default
  end

  @doc false
  # FIRST RUN. A fresh install has no credential, so no agent can run — but the
  # dashboard used to render three tidy cards and "All 3 subsystems healthy",
  # which is true of the SUBSYSTEMS and false of the PRODUCT. A new user was
  # left to guess; the one page that fixes it (/workstations/:id) is
  # undiscoverable from here.
  #
  # So: one band, one action, and it disappears the moment a token lands.
  # Flame, because this is the canonical blocked-on-a-human case (see the brand
  # rules in CLAUDE.md — flame is reserved for exactly this).
  #
  # The command carries `__ORIGIN__`, which the `Clip` hook swaps for the real
  # browser origin at copy time. That matters because Loopyard is self-hosted:
  # the server can't know the host you actually reached (LAN IP, tunnel,
  # reverse proxy), but the browser can. Same reason the token is inline — a
  # remote fetch is gated by `PushAuth`.
  attr :step, :atom, required: true, values: [:inference, :project]
  attr :workstation, :string, required: true

  # STEP 2 — inference works, but there's nothing to point it at. Quieter than
  # the flame band: nothing is blocked or broken, the user just hasn't started
  # yet, so this is iris (interactive/"you"), not flame.
  defp start_here(%{step: :project} = assigns) do
    ~H"""
    <section class="mt-8 md:mt-12 border border-violet-300 dark:border-violet-500/40 bg-violet-50 dark:bg-violet-500/[0.06] p-5 md:p-6">
      <div class="flex items-center gap-2.5">
        <span class="w-2 h-2 rounded-full bg-violet-500 flex-none" aria-hidden="true"></span>
        <h2 class="text-body font-semibold tracking-tight text-zinc-900 dark:text-zinc-50">
          Claude's connected — now add a project
        </h2>
      </div>
      <p class="text-body text-zinc-700 dark:text-zinc-300 mt-2">
        Point Loopyard at some code and an agent takes it from there: it reads the
        stack, writes the Dockerfile and services, and boots the dev server.
      </p>
      <div class="mt-3 flex flex-col sm:flex-row sm:items-center gap-2 sm:gap-3">
        <.link
          navigate="/projects/new"
          class="focus-ring inline-flex items-center justify-center rounded-sm bg-violet-600 hover:bg-violet-500 text-white px-4 py-3 md:py-2.5 text-body font-medium transition-colors"
        >
          Add your first project
        </.link>
        <.link
          navigate={"/workstations/#{@workstation}"}
          class="focus-ring text-body py-2.5 md:py-1 text-zinc-600 dark:text-zinc-300 underline hover:text-zinc-900 dark:hover:text-zinc-100"
        >
          Connect more tools first
        </.link>
      </div>
    </section>
    """
  end

  defp start_here(assigns) do
    ~H"""
    <section class="mt-8 md:mt-12 border border-orange-300 dark:border-orange-500/40 bg-orange-50 dark:bg-orange-500/[0.06] p-5 md:p-6">
      <div class="flex items-center gap-2.5">
        <span class="w-2 h-2 rounded-full bg-orange-500 flex-none" aria-hidden="true"></span>
        <h2 class="text-body font-semibold tracking-tight text-zinc-900 dark:text-zinc-50">
          Start here — connect Claude
        </h2>
      </div>
      <p class="text-body text-zinc-700 dark:text-zinc-300 mt-2">
        Agents build everything else in Loopyard — the Dockerfile, the services, the dev
        server. None of it can start until Claude can authenticate. Run this on your Mac;
        it opens a browser to authorize and pushes a 1-year token back here.
      </p>
      <div class="mt-3">
        <LoopyardWeb.Components.Workstation.command_box
          id="start-here-claude"
          command={"curl -fsS \"__ORIGIN__/workstations/#{@workstation}/claude/setup.sh?token=#{Loopyard.PushToken.get()}\" | sh"}
        />
      </div>
      <p class="text-body text-zinc-500 dark:text-zinc-400 mt-2.5">
        This band clears itself once the token lands — nothing else to do.
      </p>
      <%!-- Secondary routes as real targets, not inline text. On a phone these
           are the escape hatch when you have no terminal (paste the token, or
           let the agent ask for it), so they have to be tappable — hence the
           py-2.5 block layout that collapses to inline spacing at md:. --%>
      <div class="mt-1 flex flex-col md:flex-row md:items-center md:gap-4">
        <.link
          navigate={"/workstations/#{@workstation}/claude"}
          class="focus-ring text-body py-2.5 md:py-1 text-zinc-600 dark:text-zinc-300 underline hover:text-zinc-900 dark:hover:text-zinc-100"
        >
          Other ways to connect
        </.link>
        <.link
          navigate={"/workstations/#{@workstation}"}
          class="focus-ring text-body py-2.5 md:py-1 text-zinc-600 dark:text-zinc-300 underline hover:text-zinc-900 dark:hover:text-zinc-100"
        >
          All your tools
        </.link>
      </div>
    </section>
    """
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :ws, workspace_stats(assigns.tree))
    assigns = assign(assigns, :recent, recent_workspaces(assigns.tree))

    ~H"""
    <%!-- The ENTRANCE uses the SAME page_shell as every other route. It used to
         render a bespoke layout — no top bar, a large floating wordmark — so
         navigating "/" -> "/workspaces" made the whole frame jump: the mark
         shrank into a breadcrumb and a header with the mode icons appeared out
         of nowhere. Chrome that moves when you navigate reads as instability.
         Same shell, same gutters, same header; only the content changes.

         It names itself "Home" for the same reason: with an empty trail the
         brand crumb WAS the current page, so it centred and the top-left —
         where the brand sits on every other screen — was empty. --%>
    <.page_shell
      breadcrumbs={[{"Loopyard", "/"}, {"Home", nil}]}
      up={false}
      iex_session={@iex_session}
      max_width={:xl}
      flash={@flash}
    >
      <div>
        <.start_here :if={@first_run_step} step={@first_run_step} workstation={@workstation} />

        <div class="mt-6 grid grid-cols-1 gap-4 md:grid-cols-2 md:items-start">
          <%!-- ── WORKSPACES ─────────────────────────────────────────────── --%>
          <.dash_card title="Workspaces" navigate="/workspaces">
            <:icon>
              <svg
                viewBox="0 0 20 20"
                fill="currentColor"
                class="w-5 h-5 text-violet-600 dark:text-violet-400"
                aria-hidden="true"
              >
                <path d="M3 3.5A1.5 1.5 0 0 1 4.5 2h3A1.5 1.5 0 0 1 9 3.5v3A1.5 1.5 0 0 1 7.5 8h-3A1.5 1.5 0 0 1 3 6.5v-3ZM3 13.5A1.5 1.5 0 0 1 4.5 12h3A1.5 1.5 0 0 1 9 13.5v3A1.5 1.5 0 0 1 7.5 18h-3A1.5 1.5 0 0 1 3 16.5v-3ZM11 3.5A1.5 1.5 0 0 1 12.5 2h3A1.5 1.5 0 0 1 17 3.5v3A1.5 1.5 0 0 1 15.5 8h-3A1.5 1.5 0 0 1 11 6.5v-3ZM11 13.5a1.5 1.5 0 0 1 1.5-1.5h3a1.5 1.5 0 0 1 1.5 1.5v3a1.5 1.5 0 0 1-1.5 1.5h-3a1.5 1.5 0 0 1-1.5-1.5v-3Z" />
              </svg>
            </:icon>
            <.gauge navigate="/workspaces" tone={(@ws.working > 0 && :working) || :calm}>
              {(@ws.working > 0 && "#{@ws.working} #{plural(@ws.working, "workspace")} working") ||
                "Nothing running"}
              <:detail>
                {@ws.projects} {plural(@ws.projects, "project")} · {@ws.workspaces} {plural(
                  @ws.workspaces,
                  "workspace"
                )} · {@ws.agents} {plural(@ws.agents, "agent")}
              </:detail>
            </.gauge>
            <div class="relative z-10 mt-4 space-y-1">
              <.link
                :for={w <- @recent}
                navigate={w.path}
                class="flex items-center gap-2 -mx-2 px-2 py-3 md:py-1.5 hover:bg-zinc-100 dark:hover:bg-zinc-800/60 transition-colors"
              >
                <LoopyardWeb.Components.Common.workspace_identity
                  project={w.project}
                  workspace={w.workspace}
                  state={w.state}
                  class="min-w-0 flex-1"
                />
              </.link>
            </div>
          </.dash_card>

          <%!-- ── NOTIFICATIONS ──────────────────────────────────────────── --%>
          <.dash_card title="Notifications" navigate="/notifications">
            <:icon>
              <svg
                viewBox="0 0 20 20"
                fill="currentColor"
                class="w-5 h-5 text-violet-600 dark:text-violet-400"
                aria-hidden="true"
              >
                <path
                  fill-rule="evenodd"
                  d="M1 11.27c0-.246.033-.492.099-.73l1.523-5.521A2.75 2.75 0 0 1 5.273 3h9.454a2.75 2.75 0 0 1 2.651 2.019l1.523 5.52c.066.239.099.485.099.732V15a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2v-3.73Zm3.068-5.852A1.25 1.25 0 0 1 5.273 4.5h9.454a1.25 1.25 0 0 1 1.205.918l1.523 5.52c.006.02.01.041.015.062H14a1 1 0 0 0-.86.49l-.606 1.02a1 1 0 0 1-.86.49H8.236a1 1 0 0 1-.894-.553l-.448-.894A1 1 0 0 0 6 11H2.53l.015-.062 1.523-5.52Z"
                  clip-rule="evenodd"
                />
              </svg>
            </:icon>
            <%!-- The gauge NAMES what's waiting. "6 waiting on you" prompts the
                 only question that matters — six WHAT? — and answers none of
                 them; the noun does. --%>
            <.gauge
              navigate="/notifications"
              tone={(!@attention_loaded? && :calm) || (@waiting > 0 && :needs_you) || :calm}
            >
              {cond do
                not @attention_loaded? -> "Checking for decisions…"
                @waiting > 0 -> attention_headline(@attention)
                true -> "No decisions waiting"
              end}
              <:detail>
                {(@digest != [] && "#{length(@digest)} finished — keep going?") ||
                  "The team's inbox — anyone can act"}
              </:detail>
            </.gauge>

            <div class="relative z-10 mt-4 space-y-1">
              <%!-- The items THEMSELVES, in their own words — a decision is one
                   tap from here, which is the whole job of this card. A count
                   makes you go look; the question makes you answer it. --%>
              <.link
                :for={item <- Enum.take(@attention, 4)}
                navigate={
                  (item.msg && "/notifications/#{item.agent_id}/#{item.msg.id}") ||
                    "/notifications"
                }
                class="block -mx-2 px-2 py-3 md:py-1.5 hover:bg-zinc-100 dark:hover:bg-zinc-800/60 transition-colors"
              >
                <span class="text-body text-zinc-700 dark:text-zinc-200 line-clamp-2">
                  {item.label}
                </span>
                <span
                  :if={item.workspace_name}
                  class="block text-meta text-zinc-500 dark:text-zinc-400 mt-0.5"
                >
                  {item.project_name} · {item.workspace_name}
                </span>
              </.link>
              <.link
                :if={length(@attention) > 4}
                navigate="/notifications"
                class="block -mx-2 px-2 py-3 md:py-1.5 text-body font-medium text-orange-700 dark:text-orange-400 hover:underline"
              >
                +{length(@attention) - 4} more to decide →
              </.link>

              <%!-- What finished while you were away — the agent's own closing
                   line, each a tap from Keep going / Open / Dismiss. --%>
              <div
                :if={@digest != []}
                class={[
                  "pt-3 mt-2",
                  @attention != [] && "border-t border-zinc-200/70 dark:border-zinc-800"
                ]}
              >
                <p class="text-body text-zinc-400 dark:text-zinc-500 mb-1">Finished — keep going?</p>
                <.link
                  :for={e <- Enum.take(@digest, if(@attention == [], do: 5, else: 3))}
                  navigate={digest_path(e)}
                  class="block -mx-2 px-2 py-3 md:py-1 hover:bg-zinc-100 dark:hover:bg-zinc-800/60 transition-colors"
                >
                  <span class="text-body text-zinc-600 dark:text-zinc-400 line-clamp-2">
                    {e[:summary]}
                  </span>
                </.link>
              </div>

              <p
                :if={@attention_loaded? and @attention == [] and @digest == []}
                class="py-3 md:py-1.5 text-body text-zinc-500 dark:text-zinc-400"
              >
                Nothing waiting on you.
              </p>
            </div>
          </.dash_card>

          <%!-- ── AGENTS ─────────────────────────────────────────────────── --%>
          <.dash_card title="Agents" navigate="/agents">
            <:icon>
              <span class="text-violet-600 dark:text-violet-400"><Brand.mark class="w-5 h-5" /></span>
            </:icon>
            <.gauge navigate="/agents" tone={(@agents_working > 0 && :working) || :calm}>
              {length(@agent_rows)} {plural(length(@agent_rows), "agent")} · {@agents_working} working
              <:detail>Running the shop as {@workstation}</:detail>
            </.gauge>
            <div class="relative z-10 mt-4 space-y-1">
              <LoopyardWeb.AgentsLive.Row.agent_row
                :for={row <- Enum.take(@agent_rows, 4)}
                row={row}
                compact
              />
              <.link
                :if={length(@agent_rows) > 4}
                navigate="/agents"
                class="block -mx-2 px-2 py-3 md:py-1.5 text-body font-medium text-violet-600 dark:text-violet-400 hover:underline"
              >
                All {length(@agent_rows)} agents →
              </.link>
            </div>
          </.dash_card>

          <%!-- ── SYSTEM ─────────────────────────────────────────────────── --%>
          <%!-- ── CONFIGURATION ──────────────────────────────────────────
               The host, its ports, its secrets and the workstation's
               credentials are ONE kind of thing: settings you visit, not work
               in motion. As four cards they made the page a jagged wall of
               panels of unequal height and gave setup the same weight as the
               three roots. One card, four rows, each with the one fact you'd
               have opened it for. --%>
          <.dash_card title="Configuration" navigate="/system">
            <:icon>
              <svg
                viewBox="0 0 20 20"
                fill="currentColor"
                class="w-5 h-5 text-zinc-500 dark:text-zinc-400"
                aria-hidden="true"
              >
                <path
                  fill-rule="evenodd"
                  d="M7.84 1.804A1 1 0 0 1 8.82 1h2.36a1 1 0 0 1 .98.804l.331 1.652a6.993 6.993 0 0 1 1.929 1.115l1.598-.54a1 1 0 0 1 1.186.447l1.18 2.044a1 1 0 0 1-.205 1.251l-1.267 1.113a7.047 7.047 0 0 1 0 2.228l1.267 1.113a1 1 0 0 1 .206 1.25l-1.18 2.045a1 1 0 0 1-1.187.447l-1.598-.54a6.993 6.993 0 0 1-1.929 1.115l-.33 1.652a1 1 0 0 1-.98.804H8.82a1 1 0 0 1-.98-.804l-.331-1.652a6.993 6.993 0 0 1-1.929-1.115l-1.598.54a1 1 0 0 1-1.186-.447l-1.18-2.044a1 1 0 0 1 .205-1.251l1.267-1.114a7.05 7.05 0 0 1 0-2.227L1.821 7.773a1 1 0 0 1-.206-1.25l1.18-2.045a1 1 0 0 1 1.187-.447l1.598.54A6.992 6.992 0 0 1 7.51 3.456l.33-1.652Z"
                  clip-rule="evenodd"
                />
              </svg>
            </:icon>
            <.gauge
              navigate="/system"
              tone={
                (@first_run_step == :inference && :caution) ||
                  (@health == :healthy && :ok) ||
                  (@health == :degraded && :needs_you) ||
                  (@health == :down && :down) || :calm
              }
            >
              {system_line(@health, @first_run_step)}
              <:detail>
                {(@remote_exposed && "Reachable on #{@host}") || "Private to this machine"} · bound to {@bind}
              </:detail>
            </.gauge>
            <div class="relative z-10 mt-4">
              <.config_row navigate="/system" label="System" value={host_line(@health_map)} />
              <.config_row navigate="/system/ports" label="Ports" value={ports_line(@ports)} />
              <.config_row
                navigate="/system/secrets"
                label="Secrets"
                value={secrets_line(@secret_count)}
              />
              <.config_row
                navigate={"/workstations/#{@workstation}"}
                label="Workstation"
                value={connections_line(@connections)}
              />
            </div>
          </.dash_card>
        </div>
      </div>
    </.page_shell>
    """
  end

  # Which outside services this workstation can actually authenticate to.
  #
  # These belong to a WORKSTATION, not to the host, and they show on the
  # dashboard because the pages that own them (/workstations/:id) were only
  # linked from the first-run bands, which vanish the moment Claude is
  # connected and a project exists. So the state of your credentials went
  # invisible exactly once you were past setup — and the way you found out a
  # token was missing was an agent failing mid-task with "no GitHub
  # credentials in this sandbox".
  defp connections(_host) do
    id = Loopyard.Workstation.current()

    for ig <- Loopyard.Workstation.Env.integrations() do
      %{
        label: ig.label,
        key: ig.key,
        required?: Map.get(ig, :required, false),
        connected?: Loopyard.Workstation.Env.set?(ig.key, id),
        path: "/workstations/#{id}/#{String.downcase(ig.label)}"
      }
    end
  end

  attr :navigate, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true

  # One setting: what it is, and the single fact you'd have opened it for.
  defp config_row(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class="flex items-center gap-3 -mx-2 px-2 py-2.5 md:py-1.5 hover:bg-zinc-100 dark:hover:bg-zinc-800/60 transition-colors"
    >
      <span class="flex-none text-body text-zinc-700 dark:text-zinc-300">{@label}</span>
      <span class="ml-auto min-w-0 truncate text-meta text-zinc-500 dark:text-zinc-400">
        {@value}
      </span>
    </.link>
    """
  end

  defp host_line(health_map) when map_size(health_map) == 0, do: "—"

  defp host_line(health_map) do
    case Enum.reject(health_map, &(elem(&1, 1) == :healthy)) do
      [] ->
        "#{map_size(health_map)} subsystems ok"

      bad ->
        "#{name_list(Enum.map(bad, &(elem(&1, 0) |> to_string() |> String.replace("_", " "))))} #{health_word(bad |> List.first() |> elem(1))}"
    end
  end

  # Every assigned port, exposed ones first — the registry's ETS table is the
  # same source /system/ports reads.
  defp port_rows do
    :ets.tab2list(:port_registry)
    |> Enum.map(fn {_, e} -> e end)
    |> Enum.map(fn e ->
      %{
        host_port: e.host_port,
        exposed: e.exposed,
        label: "#{workspace_label(e.workspace_id)} · #{e.service}"
      }
    end)
    |> Enum.sort_by(&{!&1.exposed, &1.host_port})
  end

  defp workspace_label(ws_id) do
    case Loopyard.WorkspaceRegistry.get_workspace(ws_id) do
      %{name: name} -> name
      _ -> String.slice(to_string(ws_id), 0, 8)
    end
  rescue
    _ -> to_string(ws_id)
  end

  defp ports_line([]), do: "No ports assigned"

  defp ports_line(ports) do
    case Enum.count(ports, & &1.exposed) do
      0 -> "#{length(ports)} #{plural(length(ports), "port")} · none exposed"
      n -> "#{n} of #{length(ports)} #{plural(length(ports), "port")} exposed"
    end
  end

  defp secrets_line(0), do: "No secrets stored"
  defp secrets_line(n), do: "#{n} #{plural(n, "secret")} stored"

  # NAME things, don't count them: "1 not connected" begs the question it exists
  # to answer — one WHAT? And an integration you never set up is not a fault, so
  # the gauge reports what this workstation CAN do and only raises its voice for
  # a required one (no Claude, no agents). Fly missing is not news.
  defp connections_line([]), do: "No integrations"

  defp connections_line(cs) do
    case Enum.filter(cs, &(&1.required? and !&1.connected?)) do
      [] -> connected_line(Enum.filter(cs, & &1.connected?))
      missing -> "#{name_list(Enum.map(missing, & &1.label))} not connected — agents can't run"
    end
  end

  defp connected_line([]), do: "Nothing connected yet"
  defp connected_line(cs), do: "#{name_list(Enum.map(cs, & &1.label))} connected"

  defp name_list([a]), do: a
  defp name_list([a, b]), do: "#{a} and #{b}"
  defp name_list([a, b | rest]), do: "#{a}, #{b} and #{length(rest)} more"

  # ── derived values ────────────────────────────────────────────────────────

  # The 4 most recently active workspaces — the deep links into the mode.
  defp recent_workspaces(tree) do
    for p <- tree, w <- p.workspaces do
      agent = List.first(w[:agents] || [])

      %{
        project: p.name,
        workspace: w.name,
        state: ws_state(w),
        at: w[:last_activity_at] || DateTime.from_unix!(0),
        path:
          (agent && "/projects/#{p.id}/workspaces/#{w.id}/agents/#{agent.id}") ||
            "/projects/#{p.id}/workspaces/#{w.id}"
      }
    end
    |> Enum.sort_by(& &1.at, {:desc, DateTime})
    |> Enum.take(8)
  end

  @working_statuses [:thinking, :compacting, :booting, :backoff, :rate_limited]

  defp ws_state(w) do
    statuses = Enum.map(w[:agents] || [], & &1.status)

    cond do
      w[:needs_you] -> :needs_you
      w[:broken] -> :broken
      Enum.any?(statuses, &(&1 in @working_statuses)) -> :working
      Enum.any?(statuses, &(&1 == :idle)) -> :done
      true -> :asleep
    end
  end

  defp workspace_stats(tree) do
    agents = Enum.flat_map(tree, fn p -> Enum.flat_map(p.workspaces, & &1.agents) end)

    %{
      projects: length(tree),
      workspaces: Enum.sum(Enum.map(tree, &length(&1.workspaces))),
      agents: length(agents),
      working: Enum.count(agents, &(&1.status == :thinking))
    }
  end

  defp health_line(:healthy) do
    n = length(Loopyard.Health.components())
    "All #{n} subsystems healthy"
  rescue
    _ -> "All subsystems healthy"
  end

  defp health_line(:degraded), do: "A subsystem is degraded — tap for detail"
  defp health_line(:down), do: "A subsystem is down — tap for detail"
  defp health_line(_), do: "Status unavailable"

  @doc """
  A dashboard card: bordered panel, icon + title, whole-card link.

  The three cards on this page each hand-assembled the same chrome and the same
  title row — which is how the title on one of them ended up a different size
  from its neighbours. The chrome lives here now, so there is one place to
  change it and no way for the three to disagree.
  """
  attr :title, :string, required: true
  attr :navigate, :string, required: true
  slot :icon, required: true
  slot :inner_block, required: true

  def dash_card(assigns) do
    ~H"""
    <section class="relative min-w-0 border border-zinc-200 dark:border-zinc-800 bg-white/60 dark:bg-white/[0.03] p-5 md:p-6">
      <%!-- The whole card is the target; inner links sit above it on z-10. --%>
      <.link navigate={@navigate} class="absolute inset-0 focus-ring" aria-label={@title}></.link>
      <div class="flex items-center gap-2.5 text-zinc-900 dark:text-zinc-50">
        {render_slot(@icon)}
        <h2 class="text-lead font-semibold tracking-tight">{@title}</h2>
      </div>
      {render_slot(@inner_block)}
    </section>
    """
  end

  @doc """
  A card's status gauge: the one line that says how this system is doing, sitting
  directly under the title where it's read as a sentence — not as a badge floated
  into the top-right corner, where a lone word ("healthy", "6") has to carry
  meaning it can't. Tappable, because a status you can't act on is decoration.

  Tone is meaning, not decoration: `:needs_you` flame is the ONLY thing that
  claims a human, `:ok` moss confirms, `:caution` amber is transitional,
  `:down` rose alarms, `:working` iris is the system busy on its own, `:calm`
  is the quiet default.
  """
  attr :navigate, :string, required: true
  attr :tone, :atom, default: :calm, values: [:calm, :ok, :working, :caution, :needs_you, :down]
  slot :inner_block, required: true
  slot :detail

  def gauge(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class="group relative z-10 block -mx-2 mt-2 px-2 py-1.5 rounded-sm hover:bg-zinc-100 dark:hover:bg-zinc-800/60 transition-colors"
    >
      <span class={["block text-body font-medium", gauge_tone(@tone)]}>
        {render_slot(@inner_block)}
        <span class="opacity-0 group-hover:opacity-100 transition-opacity">&rarr;</span>
      </span>
      <span :if={@detail != []} class="block text-meta text-zinc-500 dark:text-zinc-400 mt-0.5">
        {render_slot(@detail)}
      </span>
    </.link>
    """
  end

  defp gauge_tone(:needs_you), do: "text-orange-700 dark:text-orange-400"
  defp gauge_tone(:ok), do: "text-emerald-700 dark:text-emerald-400"
  defp gauge_tone(:caution), do: "text-amber-600 dark:text-amber-400"
  defp gauge_tone(:down), do: "text-rose-600 dark:text-rose-400"
  defp gauge_tone(:working), do: "text-violet-600 dark:text-violet-400"
  defp gauge_tone(_), do: "text-zinc-600 dark:text-zinc-300"

  # "6 waiting on you" begs the question it should answer — six WHAT? The
  # noun is DECISION, always: a "question" here may be an agent telling you
  # something and needing a call on it, and an approval or a secret is a
  # decision too. Splitting them ("10 questions · 1 approval") named the
  # card mechanics, not the thing you have to do.
  defp attention_headline(items) do
    "#{length(items)} #{plural(length(items), "decision")} waiting on you"
  end

  # Open FINISHED items from the inbox — the agent's own closing line — each
  # linking to its slide, where Keep going / Open / Dismiss live.
  defp finished_items do
    Loopyard.Notifications.open([:finished])
    |> Enum.take(6)
    |> Enum.map(&%{summary: &1.label, agent_id: &1.agent_id})
  end

  defp digest_path(%{agent_id: aid}) when is_binary(aid),
    do: "/notifications/#{aid}/#{LoopyardWeb.NotificationsLive.Deck.finished_msg_id()}"

  defp digest_path(_), do: "/notifications"

  defp plural(1, word), do: word
  defp plural(_, word), do: word <> "s"
end
