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

  import LoopyardWeb.Components.Common, only: [flash_banner: 1]

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
    |> assign(:remote_exposed, safe(&Loopyard.HostExposer.exposed?/0, false))
    |> assign(:operator, safe(&Loopyard.Workstation.current/0, "—"))
    |> assign(:operator_count, safe(fn -> length(Loopyard.Workstation.list()) end, 1))
    |> assign(:waiting, safe(&Loopyard.Attention.count/0, 0))
    |> assign(:inference_ready?, safe(&inference_ready?/0, true))
  end

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
  attr :workstation, :string, required: true

  defp start_here(assigns) do
    ~H"""
    <section class="mt-8 md:mt-12 border border-orange-300 dark:border-orange-500/40 bg-orange-50 dark:bg-orange-500/[0.06] p-5 md:p-6">
      <div class="flex items-center gap-2.5">
        <span class="w-2 h-2 rounded-full bg-orange-500 flex-none" aria-hidden="true"></span>
        <h2 class="text-base font-semibold tracking-tight text-zinc-900 dark:text-zinc-50">
          Start here — connect Claude
        </h2>
      </div>
      <p class="chat-sub text-zinc-700 dark:text-zinc-300 mt-2">
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
      <p class="chat-meta text-zinc-500 dark:text-zinc-400 mt-2.5">
        This band clears itself once the token lands — nothing else to do.
      </p>
      <%!-- Secondary routes as real targets, not inline text. On a phone these
           are the escape hatch when you have no terminal (paste the token, or
           let the agent ask for it), so they have to be tappable — hence the
           py-2.5 block layout that collapses to inline spacing at md:. --%>
      <div class="mt-1 flex flex-col md:flex-row md:items-center md:gap-4">
        <.link
          navigate={"/workstations/#{@workstation}/claude"}
          class="focus-ring chat-meta py-2.5 md:py-1 text-zinc-600 dark:text-zinc-300 underline hover:text-zinc-900 dark:hover:text-zinc-100"
        >
          Other ways to connect
        </.link>
        <.link
          navigate={"/workstations/#{@workstation}"}
          class="focus-ring chat-meta py-2.5 md:py-1 text-zinc-600 dark:text-zinc-300 underline hover:text-zinc-900 dark:hover:text-zinc-100"
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
    <%!-- The ENTRANCE: no app top bar — the page IS the nav. A quiet wordmark,
         then the three modes (plans/ia-two-modes.md), each an icon-led panel
         with live status + deep links into its second level. An app, not a
         marketing hero: one screen, everything reachable. --%>
    <div class="min-h-screen bg-brand-paper dark:bg-brand-ink text-zinc-900 dark:text-zinc-100 safe-area-x safe-area-top">
      <.flash_banner flash={@flash} kind={:error} />
      <.flash_banner flash={@flash} kind={:info} />

      <div class="mx-auto max-w-6xl px-4 md:px-8 pt-10 md:pt-16 pb-10">
        <Brand.logo mark_class="w-6 h-6 flex-none" wordmark_class="text-lg tracking-tight" />

        <.start_here :if={not @inference_ready?} workstation={@operator} />

        <div class="mt-8 md:mt-12 grid gap-4 md:grid-cols-3">
          <%!-- ── WORKSPACES ─────────────────────────────────────────────── --%>
          <section class="relative border border-zinc-200 dark:border-zinc-800 bg-white/60 dark:bg-white/[0.03] p-5 md:p-6">
            <.link navigate="/workspaces" class="absolute inset-0 focus-ring" aria-label="Workspaces"></.link>
            <div class="flex items-center gap-2.5 text-zinc-900 dark:text-zinc-50">
              <svg
                viewBox="0 0 20 20"
                fill="currentColor"
                class="w-5 h-5 text-violet-600 dark:text-violet-400"
                aria-hidden="true"
              >
                <path d="M3 3.5A1.5 1.5 0 0 1 4.5 2h3A1.5 1.5 0 0 1 9 3.5v3A1.5 1.5 0 0 1 7.5 8h-3A1.5 1.5 0 0 1 3 6.5v-3ZM3 13.5A1.5 1.5 0 0 1 4.5 12h3A1.5 1.5 0 0 1 9 13.5v3A1.5 1.5 0 0 1 7.5 18h-3A1.5 1.5 0 0 1 3 16.5v-3ZM11 3.5A1.5 1.5 0 0 1 12.5 2h3A1.5 1.5 0 0 1 17 3.5v3A1.5 1.5 0 0 1 15.5 8h-3A1.5 1.5 0 0 1 11 6.5v-3ZM11 13.5a1.5 1.5 0 0 1 1.5-1.5h3a1.5 1.5 0 0 1 1.5 1.5v3a1.5 1.5 0 0 1-1.5 1.5h-3a1.5 1.5 0 0 1-1.5-1.5v-3Z" />
              </svg>
              <h2 class="text-base font-semibold tracking-tight">Workspaces</h2>
              <span
                :if={@ws.working > 0}
                class="ml-auto chat-meta text-violet-600 dark:text-violet-400"
              >
                {@ws.working} working
              </span>
            </div>
            <p class="chat-meta text-zinc-500 dark:text-zinc-400 mt-1">
              {@ws.projects} {plural(@ws.projects, "project")} · {@ws.workspaces} {plural(
                @ws.workspaces,
                "workspace"
              )} · {@ws.agents} {plural(@ws.agents, "agent")}
            </p>
            <div class="relative z-10 mt-4 space-y-1">
              <.link
                :for={w <- @recent}
                navigate={w.path}
                class="flex items-center gap-2 -mx-2 px-2 py-2 md:py-1.5 hover:bg-zinc-100 dark:hover:bg-zinc-800/60 transition-colors"
              >
                <LoopyardWeb.Components.Common.workspace_identity
                  project={w.project}
                  workspace={w.workspace}
                  state={w.state}
                  size={:sm}
                  class="min-w-0 flex-1"
                />
              </.link>
            </div>
          </section>

          <%!-- ── OPERATOR ───────────────────────────────────────────────── --%>
          <section class="relative border border-zinc-200 dark:border-zinc-800 bg-white/60 dark:bg-white/[0.03] p-5 md:p-6">
            <.link navigate="/operator" class="absolute inset-0 focus-ring" aria-label="Operator"></.link>
            <div class="flex items-center gap-2.5 text-zinc-900 dark:text-zinc-50">
              <span class="text-violet-600 dark:text-violet-400"><Brand.mark class="w-5 h-5" /></span>
              <h2 class="text-base font-semibold tracking-tight">Operator</h2>
              <span
                :if={@waiting > 0}
                class="ml-auto chat-meta font-semibold text-orange-700 dark:text-orange-400"
              >
                {@waiting} waiting on you
              </span>
            </div>
            <p class="chat-meta text-zinc-500 dark:text-zinc-400 mt-1">
              Running the shop as
              <span class="font-medium text-zinc-700 dark:text-zinc-300">{@operator}</span>
            </p>
            <div class="relative z-10 mt-4 space-y-1">
              <.link
                navigate="/operator"
                class="flex items-center gap-2 -mx-2 px-2 py-2 md:py-1.5 chat-meta text-zinc-700 dark:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800/60 transition-colors"
              >
                Chat with the operator
              </.link>
              <.link
                navigate="/review"
                class="flex items-center gap-2 -mx-2 px-2 py-2 md:py-1.5 chat-meta text-zinc-700 dark:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800/60 transition-colors"
              >
                For you
                <span :if={@waiting > 0} class="text-orange-700 dark:text-orange-400 font-semibold">{@waiting}</span>
              </.link>
              <.link
                navigate="/workstations"
                class="flex items-center gap-2 -mx-2 px-2 py-2 md:py-1.5 chat-meta text-zinc-700 dark:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800/60 transition-colors"
              >
                Workstations · {@operator_count}
              </.link>
            </div>
          </section>

          <%!-- ── SYSTEM ─────────────────────────────────────────────────── --%>
          <section class="relative border border-zinc-200 dark:border-zinc-800 bg-white/60 dark:bg-white/[0.03] p-5 md:p-6">
            <.link navigate="/system" class="absolute inset-0 focus-ring" aria-label="System"></.link>
            <div class="flex items-center gap-2.5 text-zinc-900 dark:text-zinc-50">
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
              <h2 class="text-base font-semibold tracking-tight">System</h2>
              <span class={[
                "ml-auto chat-meta font-semibold",
                (@health == :healthy && "text-emerald-600 dark:text-emerald-400") ||
                  (@health == :degraded && "text-orange-700 dark:text-orange-400") ||
                  (@health == :down && "text-rose-600 dark:text-rose-400") ||
                  "text-zinc-400"
              ]}>
                {@health}
              </span>
            </div>
            <p class="chat-meta text-zinc-500 dark:text-zinc-400 mt-1">
              {health_line(@health)} · {(@remote_exposed && "reachable on #{@host}") ||
                "private to this machine"}
            </p>
            <div class="relative z-10 mt-4 space-y-1">
              <.link
                navigate="/system"
                class="flex items-center gap-2 -mx-2 px-2 py-2 md:py-1.5 chat-meta text-zinc-700 dark:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800/60 transition-colors"
              >
                Health
              </.link>
              <.link
                navigate="/system/ports"
                class="flex items-center gap-2 -mx-2 px-2 py-2 md:py-1.5 chat-meta text-zinc-700 dark:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800/60 transition-colors"
              >
                Ports
              </.link>
              <.link
                navigate="/system/secrets"
                class="flex items-center gap-2 -mx-2 px-2 py-2 md:py-1.5 chat-meta text-zinc-700 dark:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800/60 transition-colors"
              >
                Secrets
              </.link>
              <.link
                navigate="/remote/"
                class="flex items-center gap-2 -mx-2 px-2 py-2 md:py-1.5 chat-meta text-zinc-700 dark:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800/60 transition-colors"
              >
                Remote · {(@remote_exposed && "exposed") || "private"}
              </.link>
            </div>
          </section>
        </div>
      </div>
    </div>
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
    |> Enum.take(4)
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

  defp plural(1, word), do: word
  defp plural(_, word), do: word <> "s"
end
