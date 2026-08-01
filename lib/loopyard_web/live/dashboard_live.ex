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
    |> assign(:operator, safe(&Loopyard.Workstation.current/0, "—"))
    |> assign(:operator_count, safe(fn -> length(Loopyard.Workstation.list()) end, 1))
    |> then(fn socket ->
      # The line itself, not just its length — the card shows the actual asks.
      items = safe(fn -> Loopyard.Attention.line() end, [])

      socket
      |> assign(:attention, items)
      |> assign(:waiting, length(items))
    end)
    |> assign(:inference_ready?, safe(&inference_ready?/0, true))
    |> assign(:digest, safe(fn -> Loopyard.Operator.Digest.recent(6) end, []))
    |> assign(:health_map, safe(&Loopyard.Health.overall/0, %{}))
    |> then(&assign(&1, :first_run_step, first_run_step(&1.assigns)))
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
  defp health_dot(:healthy), do: "bg-emerald-500"
  defp health_dot({:degraded, _}), do: "bg-amber-500"
  defp health_dot({:down, _}), do: "bg-rose-500"
  defp health_dot(_), do: "bg-zinc-400"

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
         Same shell, same gutters, same header; only the content changes. --%>
    <.page_shell
      breadcrumbs={[]}
      iex_session={@iex_session}
      max_width={:xl}
      flash={@flash}
    >
      <div>
        <.start_here :if={@first_run_step} step={@first_run_step} workstation={@operator} />

        <div class="mt-6 grid gap-4 md:grid-cols-3 md:auto-rows-fr lg:min-h-[26rem]">
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

          <%!-- ── OPERATOR ───────────────────────────────────────────────── --%>
          <.dash_card title="Operator" navigate="/operator">
            <:icon>
              <span class="text-violet-600 dark:text-violet-400"><Brand.mark class="w-5 h-5" /></span>
            </:icon>
            <%!-- The gauge NAMES what's waiting. "6 waiting on you" prompts the
                 only question that matters — six WHAT? — and answers none of
                 them; the breakdown by kind does. --%>
            <.gauge navigate="/review" tone={(@waiting > 0 && :needs_you) || :calm}>
              {(@waiting > 0 && attention_headline(@attention)) || "No decisions waiting"}
              <:detail>Running the shop as {@operator}</:detail>
            </.gauge>

            <div class="relative z-10 mt-4 space-y-1">
              <%!-- The items THEMSELVES, in their own words — a decision is one
                   tap from here, which is the whole job of this card. A count
                   makes you go look; the question makes you answer it. --%>
              <.link
                :for={item <- Enum.take(@attention, 4)}
                navigate={(item.msg && "/review/#{item.agent_id}/#{item.msg.id}") || "/review"}
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
                navigate="/review"
                class="block -mx-2 px-2 py-3 md:py-1.5 text-body font-medium text-orange-700 dark:text-orange-400 hover:underline"
              >
                +{length(@attention) - 4} more to decide →
              </.link>

              <.link
                :if={@attention == []}
                navigate="/operator"
                class="flex items-center gap-2 -mx-2 px-2 py-3 md:py-1.5 text-body text-zinc-700 dark:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800/60 transition-colors"
              >
                Chat with the operator
              </.link>

              <%!-- What actually happened while you were away — the agent's own
                   closing line, not "finished a turn" (true of every entry, so
                   it tells you nothing). Hidden on phones. --%>
              <div
                :if={@digest != []}
                class="hidden md:block pt-3 mt-2 border-t border-zinc-200/70 dark:border-zinc-800"
              >
                <p class="text-body text-zinc-400 dark:text-zinc-500 mb-1">Recently finished</p>
                <.link
                  :for={e <- Enum.take(@digest, if(@attention == [], do: 5, else: 3))}
                  navigate={digest_path(e)}
                  class="block -mx-2 px-2 py-1 hover:bg-zinc-100 dark:hover:bg-zinc-800/60 transition-colors"
                >
                  <span class="text-body text-zinc-600 dark:text-zinc-400 line-clamp-2">
                    {e[:summary]}
                  </span>
                </.link>
              </div>
            </div>
          </.dash_card>

          <%!-- ── SYSTEM ─────────────────────────────────────────────────── --%>
          <.dash_card title="System" navigate="/system">
            <:icon>
              <svg
                viewBox="0 0 20 20"
                fill="currentColor"
                class="w-5 h-5 text-zinc-500 dark:text-zinc-400"
                aria-hidden="true"
              >
                <path
                  fill-rule="evenodd"
                  d="M7.84 1.804A1 1 0 0 1 8.82 1h2.36a1 1 0 0 1 .98.804l.331 1.652a6.993 6.993 0 0 1 1.929 1.115l1.598-.54a1 1 0 0 1 1.186.447l1.18 2.044a1 1 0 0 1-.205 1.251l-1.267 1.113a7.047 7.047 0 0 1 0 2.228l1.267 1.113a1 1 0 0 1 .206 1.25l-1.18 2.045a1 1 0 0 1-1.187.447l-1.598-.54a6.993 6.993 0 0 1-1.929 1.115l-.33 1.652a1 1 0 0 1-.98.804H8.82a1 1 0 0 1-.98-.804l-.331-1.652a6.993 6.993 0 0 1-1.929-1.115l-1.598.54a1 1 0 0 1-1.186-.447l-1.18-2.044a1 1 0 0 1 .205-1.251l1.267-1.114a7.05 7.05 0 0 1 0-2.227L1.821 7.773a1 1 0 0 1-.206-1.25l1.18-2.045a1 1 0 0 1 1.187-.447l1.598.54A6.992 6.992 0 0 1 7.51 3.456l.33-1.652ZM10 13a3 3 0 1 0 0-6 3 3 0 0 0 0 6Z"
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
            <div class="relative z-10 mt-4 space-y-1">
              <.link
                navigate="/system"
                class="flex items-center gap-2 -mx-2 px-2 py-3 md:py-1.5 text-body text-zinc-700 dark:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800/60 transition-colors"
              >
                Health
              </.link>
              <.link
                navigate="/system/ports"
                class="flex items-center gap-2 -mx-2 px-2 py-3 md:py-1.5 text-body text-zinc-700 dark:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800/60 transition-colors"
              >
                Ports
              </.link>
              <.link
                navigate="/system/secrets"
                class="flex items-center gap-2 -mx-2 px-2 py-3 md:py-1.5 text-body text-zinc-700 dark:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800/60 transition-colors"
              >
                Secrets
              </.link>
              <%!-- Per-component health. "All 3 subsystems healthy" is a summary
                   of exactly this; showing the components themselves is what
                   makes the card worth looking at when one of them ISN'T
                   healthy — you can see WHICH without navigating. --%>
              <div
                :if={@health_map != %{}}
                class="hidden md:block pt-3 mt-2 border-t border-zinc-200/70 dark:border-zinc-800"
              >
                <p class="text-body text-zinc-400 dark:text-zinc-500 mb-1">Subsystems</p>
                <div
                  :for={{comp, status} <- Enum.sort_by(@health_map, &elem(&1, 0))}
                  class="flex items-center gap-2 text-body py-0.5"
                >
                  <span class={["w-1.5 h-1.5 rounded-full flex-none", health_dot(status)]}></span>
                  <span class="text-zinc-600 dark:text-zinc-400">
                    {comp |> to_string() |> String.replace("_", " ")}
                  </span>
                  <span class="ml-auto text-zinc-400 dark:text-zinc-500 truncate">
                    {health_word(status)}
                  </span>
                </div>
              </div>
            </div>
          </.dash_card>
        </div>
      </div>
    </.page_shell>
    """
  end

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
    <section class="relative border border-zinc-200 dark:border-zinc-800 bg-white/60 dark:bg-white/[0.03] p-5 md:p-6">
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

  # "6 waiting on you" begs the question it should answer. Name the nouns:
  # "4 questions · 2 approvals".
  defp attention_headline(items) do
    counts = Enum.frequencies_by(items, & &1.kind)

    [question: "question", approval: "approval", secret: "secret"]
    |> Enum.filter(fn {kind, _} -> counts[kind] end)
    |> Enum.map_join(" · ", fn {kind, noun} ->
      "#{counts[kind]} #{plural(counts[kind], noun)}"
    end)
    |> case do
      "" -> "#{length(items)} #{plural(length(items), "decision")} waiting on you"
      line -> line <> " waiting on you"
    end
  end

  # A digest row goes where the work happened, so "what finished" is one tap
  # from the thing itself.
  defp digest_path(%{project_id: pid, workspace_id: ws, agent_id: aid})
       when is_binary(pid) and is_binary(ws) and is_binary(aid),
       do: "/projects/#{pid}/workspaces/#{ws}/agents/#{aid}"

  defp digest_path(_), do: "/operator"

  defp plural(1, word), do: word
  defp plural(_, word), do: word <> "s"
end
