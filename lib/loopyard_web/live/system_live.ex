defmodule LoopyardWeb.SystemLive do
  @moduledoc """
  Cluster overview page. Shows host stats, BEAM totals, and counts.
  Drill into `/system/workspaces` and `/system/docker` for details.

  Every slow slice loads via `start_async/3` so mount paints instantly.
  Slices refresh on independent timers — fast slices (BEAM, counts)
  refresh every 2s, slow slices (host shell-outs) every 5s. A hung
  Docker call never blocks the page or other slices.
  """
  use LoopyardWeb, :live_view
  use LoopyardWeb.IExAware

  alias Phoenix.LiveView.AsyncResult
  alias Loopyard.SystemStats

  # Each slice has its own refresh cadence. Fast in-VM lookups can refresh
  # often; shell-outs to vm_stat / df / docker are kept slower so we don't
  # pile up zombie processes if the host is unhappy.
  @fast_refresh 2_000
  @slow_refresh 5_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign_iex()
      |> assign(:host_cpu, AsyncResult.loading())
      |> assign(:host_memory, AsyncResult.loading())
      |> assign(:host_disk, AsyncResult.loading())
      |> assign(:host_uptime, AsyncResult.loading())
      |> assign(:beam, SystemStats.beam_stats())
      |> assign(:counts, AsyncResult.loading())
      |> assign(:health, Loopyard.Health.overall())
      |> assign(:logs, Loopyard.LogBuffer.recent(20))

    if connected?(socket) do
      schedule_refresh(:fast)
      schedule_refresh(:slow)
      {:ok, kick_all_slices(socket)}
    else
      {:ok, socket}
    end
  end

  defp assign_iex(socket) do
    if connected?(socket),
      do: subscribe_iex(socket),
      else: assign(socket, :iex_session, %{level: nil})
  end

  defp schedule_refresh(:fast), do: Process.send_after(self(), :refresh_fast, @fast_refresh)
  defp schedule_refresh(:slow), do: Process.send_after(self(), :refresh_slow, @slow_refresh)

  # Spawn one Task per slice. They run in parallel and each populates
  # exactly one assign on completion via handle_async/3.
  defp kick_all_slices(socket) do
    socket
    |> kick_fast_slices()
    |> kick_slow_slices()
  end

  defp kick_fast_slices(socket) do
    socket
    |> start_async(:counts, &load_counts/0)
  end

  defp kick_slow_slices(socket) do
    socket
    |> start_async(:host_cpu, &SystemStats.host_cpu/0)
    |> start_async(:host_memory, &SystemStats.host_memory/0)
    |> start_async(:host_disk, &SystemStats.host_disk/0)
    |> start_async(:host_uptime, &SystemStats.host_uptime/0)
  end

  defp load_counts do
    resources = Loopyard.Resources.all()
    checkpointers = Loopyard.AgentLog.Checkpointer.list_all()
    agents = Loopyard.ChatAgent.list_agents()

    %{
      workspaces: length(Loopyard.ProjectRegistry.list_projects()),
      agents: length(agents),
      workstations: agents_per_workstation(agents),
      cli: length(SystemStats.claude_cli_processes()),
      quarantined: length(Loopyard.ChatAgent.RestartController.list_quarantined()),
      sagas: Loopyard.Saga.Recorder.summary(),
      resources: %{
        total: length(resources),
        stale: Enum.count(resources, &(not &1.owner_alive?))
      },
      recovery: %{
        total: length(checkpointers),
        failed:
          Enum.count(checkpointers, fn c ->
            match?({:error, _}, c.last_result)
          end)
      }
    }
  end

  # Running agents grouped by the workstation identity they booted from →
  # `[{identity, count}]`, busiest first. The blast radius for a credential
  # change on an identity is everyone in its bucket.
  defp agents_per_workstation(agents) do
    agents
    |> Enum.group_by(&(&1[:workstation_identity] || "—"))
    |> Enum.map(fn {identity, list} -> {identity, length(list)} end)
    |> Enum.sort_by(fn {_identity, n} -> -n end)
  end

  # --- Refresh timers ---

  @impl true
  def handle_info(:refresh_fast, socket) do
    schedule_refresh(:fast)
    # BEAM stats are pure VM lookups; refresh in-place. Tail logs too.
    # Health is also ETS-only reads, negligible cost.
    {:noreply,
     socket
     |> assign(:beam, SystemStats.beam_stats())
     |> assign(:health, Loopyard.Health.overall())
     |> assign(:logs, Loopyard.LogBuffer.recent(20))
     |> kick_fast_slices()}
  end

  def handle_info(:refresh_slow, socket) do
    schedule_refresh(:slow)
    {:noreply, kick_slow_slices(socket)}
  end

  @impl true
  def handle_event("reboot", _params, socket) do
    case Loopyard.Reboot.trigger() do
      :ok ->
        {:noreply,
         put_flash(
           socket,
           :info,
           "Rebooting the server — the runtime is restarting; the page reconnects in ~10s."
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Couldn't launch the reboot: #{inspect(reason)}")}
    end
  end

  # --- Async results ---

  @impl true
  def handle_async(key, {:ok, value}, socket) do
    {:noreply,
     assign(socket, key, AsyncResult.ok(socket.assigns[key] || AsyncResult.loading(), value))}
  end

  def handle_async(key, {:exit, reason}, socket) do
    {:noreply,
     assign(socket, key, AsyncResult.failed(socket.assigns[key] || AsyncResult.loading(), reason))}
  end

  # =============================================
  # Render
  # =============================================

  @impl true
  def render(assigns) do
    ~H"""
    <.page_shell
      mode={:system}
      breadcrumbs={[{"Loopyard", "/"}, {"System", nil}]}
      iex_session={@iex_session}
      max_width={:lg}
      flash={@flash}
    >
      <div class="space-y-8">
        <.health_section health={@health} />
        <.host_section
          host_cpu={@host_cpu}
          host_memory={@host_memory}
          host_disk={@host_disk}
          host_uptime={@host_uptime}
        />
        <.beam_section beam={@beam} />
        <.drilldown_section counts={@counts} />
        <.log_section logs={@logs} />
        <.destinations_section />
        <.reboot_section />
      </div>
    </.page_shell>
    """
  end

  # --- Host System ---

  # --- Health (component status) ---

  # The one deliberate destructive control on /system: reboot the whole runtime.
  # Lives at the BOTTOM as a confirmed danger-zone card (NOT a scary top-right
  # button) — you have to scroll past everything and confirm to hit it.
  # The rest of the System mode — destinations that used to be top-level
  # (plans/archive/ia-two-modes.md): remote access + ambient sound settings.
  defp destinations_section(assigns) do
    ~H"""
    <section class="space-y-1.5">
      <h2 class="text-body font-semibold text-zinc-900 dark:text-zinc-50">Also in System</h2>
      <div class="flex flex-wrap gap-x-6">
        <.link
          navigate="/sound"
          class="text-body inline-flex items-center min-h-11 md:min-h-0 text-violet-600 dark:text-violet-400 hover:underline"
        >
          Ambient sound →
        </.link>
      </div>
    </section>
    """
  end

  defp reboot_section(assigns) do
    ~H"""
    <section class="space-y-3">
      <h2 class="text-body font-semibold uppercase tracking-wide text-zinc-500 dark:text-zinc-400">
        Server
      </h2>
      <div class=" border border-red-200 dark:border-red-900/40 bg-red-50/40 dark:bg-red-900/10 p-4 flex items-start justify-between gap-4">
        <div class="min-w-0">
          <div class="text-body font-medium text-zinc-800 dark:text-zinc-200">Reboot the server</div>
          <p class="text-body text-zinc-500 dark:text-zinc-400 mt-0.5 max-w-prose">
            Tears the Loopyard runtime down and restarts it in place: every agent
            session stops and re-spawns (reconnecting to the running containers),
            and boot recovery re-runs. Docker containers keep running. The page
            reconnects on its own once it's back — a few seconds.
          </p>
        </div>
        <button
          type="button"
          phx-click="reboot"
          data-confirm="Reboot the server? Every agent session stops and re-spawns (containers keep running). The page reconnects when it's back up."
          class="focus-ring flex-none inline-flex items-center rounded-sm bg-red-600 hover:bg-red-700 px-4 min-h-11 md:min-h-0 md:py-2 text-body font-medium text-white transition-colors"
        >
          Reboot
        </button>
      </div>
    </section>
    """
  end

  defp health_section(assigns) do
    ~H"""
    <section>
      <h2 class="text-body font-semibold uppercase tracking-wider text-zinc-500 dark:text-zinc-400 mb-3">
        Component Health
      </h2>
      <div class="grid grid-cols-1 md:grid-cols-3 gap-3">
        <.health_card :for={{component, status} <- @health} component={component} status={status} />
      </div>
    </section>
    """
  end

  attr :component, :atom, required: true
  attr :status, :any, required: true

  defp health_card(assigns) do
    ~H"""
    <div class={health_card_class(@status)}>
      <div class="flex items-center justify-between mb-1">
        <div class="text-body font-semibold">{humanize_component(@component)}</div>
        <div class={"w-2 h-2 rounded-full " <> health_dot_class(@status)}></div>
      </div>
      <div class="text-meta text-zinc-600 dark:text-zinc-400">{Loopyard.Health.format(@status)}</div>
    </div>
    """
  end

  defp health_card_class(:healthy),
    do:
      "rounded-sm border border-emerald-200 dark:border-emerald-900/50 bg-emerald-50/50 dark:bg-emerald-900/10 px-3 py-3"

  defp health_card_class({:degraded, _}),
    do:
      "rounded-sm border border-amber-300 dark:border-amber-800 bg-amber-50 dark:bg-amber-900/20 px-3 py-3"

  defp health_card_class({:down, _}),
    do:
      "rounded-sm border border-red-300 dark:border-red-800 bg-red-50 dark:bg-red-900/20 px-3 py-3"

  defp health_dot_class(:healthy), do: "bg-emerald-500"
  defp health_dot_class({:degraded, _}), do: "bg-amber-500 animate-pulse"
  defp health_dot_class({:down, _}), do: "bg-red-500 animate-pulse"

  # The disk bar used to alarm when the percentage STRING contained a "9", so
  # 19% used — half the disk free — rendered in the colour reserved for "act
  # now". Compare the number.
  defp pct_over?(use_pct, threshold) when is_binary(use_pct) do
    case Integer.parse(use_pct) do
      {n, _} -> n >= threshold
      :error -> false
    end
  end

  defp pct_over?(_, _), do: false

  defp humanize_component(:docker), do: "Docker"
  defp humanize_component(:pubsub), do: "PubSub"
  defp humanize_component(:agent_reconciler), do: "Agent reconciler"
  defp humanize_component(other), do: other |> Atom.to_string() |> String.replace("_", " ")

  defp host_section(assigns) do
    ~H"""
    <section>
      <h2 class="text-body font-semibold uppercase tracking-wider text-zinc-500 dark:text-zinc-400 mb-3">
        Host System
      </h2>
      <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
        <.host_card :let={cpu} label="CPU" async={@host_cpu}>
          <div class="text-hero font-semibold font-mono">
            {cpu.cores} <span class="text-body text-zinc-400">cores</span>
          </div>
          <div class="mt-2 text-meta font-mono text-zinc-500">
            Load avg:
            <span
              :for={{load, i} <- Enum.with_index(cpu.load_avg)}
              class={load_color(load, cpu.cores)}
            >
              {Float.round(load, 2)}<span :if={i < 2} class="text-zinc-400">,</span>
            </span>
          </div>
        </.host_card>

        <.host_card :let={mem} label="Memory" async={@host_memory}>
          <% pct = mem_bar_pct(mem) %>
          <div class="text-hero font-semibold font-mono">
            {format_bytes(mem.used)}
            <span class="text-body text-zinc-400">/ {format_bytes(mem.total)}</span>
          </div>
          <div class="mt-2 h-2 bg-zinc-200 dark:bg-zinc-700 rounded-full overflow-hidden">
            <div
              class={"h-full rounded-full #{if pct > 80, do: "bg-red-500", else: "bg-violet-500"}"}
              style={"width: #{pct}%"}
            >
            </div>
          </div>
          <div class="mt-1 text-meta font-mono text-zinc-400">{pct}% used</div>
        </.host_card>

        <.host_card :let={disk} label="Disk (/)" async={@host_disk}>
          <div class="text-hero font-semibold font-mono">
            {disk.used} <span class="text-body text-zinc-400">/ {disk.total}</span>
          </div>
          <div class="mt-2 h-2 bg-zinc-200 dark:bg-zinc-700 rounded-full overflow-hidden">
            <div
              class={"h-full rounded-full #{(pct_over?(disk.use_pct, 90) && "bg-red-500") || "bg-violet-500"}"}
              style={"width: #{disk.use_pct}"}
            >
            </div>
          </div>
          <div class="mt-1 text-meta font-mono text-zinc-400">
            {disk.use_pct} used &middot; {disk.available} free
          </div>
        </.host_card>
      </div>
      <div class="mt-2 text-meta text-zinc-500 dark:text-zinc-400 font-mono min-h-[1em]">
        <%= case @host_uptime do %>
          <% %{ok?: true, result: uptime} -> %>
            {uptime}
          <% _ -> %>
            <span class="text-zinc-300 dark:text-zinc-600">loading uptime…</span>
        <% end %>
      </div>
    </section>
    """
  end

  # Generic card with async loading skeleton + error fallback. The slot
  # receives `:let={result}` so each card can render its own data shape
  # without re-implementing the loading/error states.
  attr :label, :string, required: true
  attr :async, :any, required: true
  slot :inner_block, required: true

  defp host_card(assigns) do
    ~H"""
    <div class="rounded-sm border border-zinc-200 dark:border-zinc-700/80 bg-zinc-50 dark:bg-zinc-800/50 p-4 min-h-[6rem]">
      <div class="section-label mb-2">
        {@label}
      </div>
      <%= case @async do %>
        <% %{ok?: true, result: result} -> %>
          {render_slot(@inner_block, result)}
        <% %{failed: failed} when failed != nil -> %>
          <div class="text-meta text-red-500">failed to load</div>
        <% _ -> %>
          <.skeleton variant={:card} />
      <% end %>
    </div>
    """
  end

  # --- BEAM ---

  defp beam_section(assigns) do
    ~H"""
    <section>
      <h2 class="text-body font-semibold uppercase tracking-wider text-zinc-500 dark:text-zinc-400 mb-3">
        BEAM VM
      </h2>
      <div class="grid grid-cols-2 md:grid-cols-4 gap-3">
        <.stat_card label="Memory" value={format_bytes(@beam.total)} />
        <.stat_card label="Processes" value={format_number(@beam.process_count)} />
        <.stat_card label="ETS" value={format_bytes(@beam.ets)} />
        <.stat_card label="Schedulers" value={@beam.schedulers} />
      </div>
    </section>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true

  defp stat_card(assigns) do
    ~H"""
    <div class="rounded-sm border border-zinc-200 dark:border-zinc-700/80 bg-zinc-50 dark:bg-zinc-800/50 px-3 py-2">
      <div class="section-label">
        {@label}
      </div>
      <div class="text-body font-semibold font-mono mt-0.5">{@value}</div>
    </div>
    """
  end

  # --- Drill-down to deeper pages ---

  defp drilldown_section(assigns) do
    ~H"""
    <section>
      <h2 class="text-body font-semibold uppercase tracking-wider text-zinc-500 dark:text-zinc-400 mb-3">
        Cluster
      </h2>
      <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-3">
        <.drilldown_card
          href="/system/ports"
          title="Ports"
          subtitle="Host port assignments + exposure"
        >
          <span class="text-zinc-400">audit + expose</span>
        </.drilldown_card>
        <.drilldown_card
          href="/system/workspaces"
          title="Workspaces"
          subtitle="Per-workspace health & restart controls"
        >
          <%= case @counts do %>
            <% %{ok?: true, result: %{workspaces: w, agents: a}} -> %>
              <span class="font-mono">{w}</span>
              workspaces · <span class="font-mono">{a}</span>
              agents
            <% _ -> %>
              <span class="text-zinc-400">loading…</span>
          <% end %>
        </.drilldown_card>

        <.drilldown_card
          href="/workstations"
          title="Workstations"
          subtitle="Running agents per identity (a credential change's blast radius)"
        >
          <%= case @counts do %>
            <% %{ok?: true, result: %{workstations: []}} -> %>
              <span class="text-zinc-400">no agents running</span>
            <% %{ok?: true, result: %{workstations: usage}} -> %>
              <span :for={{identity, n} <- usage} class="mr-2 whitespace-nowrap">
                <span class="font-mono text-zinc-700 dark:text-zinc-300">{identity}</span>
                <span class="font-mono">{n}</span>
              </span>
            <% _ -> %>
              <span class="text-zinc-400">loading…</span>
          <% end %>
        </.drilldown_card>

        <.drilldown_card
          href="/system/docker"
          title="Docker Cluster"
          subtitle="All containers, volumes, resource stats"
        >
          <%= case @counts do %>
            <% %{ok?: true, result: %{cli: cli}} -> %>
              <span class="font-mono">{cli}</span> claude CLI processes
            <% _ -> %>
              <span class="text-zinc-400">loading…</span>
          <% end %>
        </.drilldown_card>

        <.drilldown_card
          href="/system/quarantine"
          title="Quarantine"
          subtitle="Agents blocked from restart after crash loops"
        >
          <%= case @counts do %>
            <% %{ok?: true, result: %{quarantined: 0}} -> %>
              <span class="text-emerald-600 dark:text-emerald-400">0 quarantined</span>
            <% %{ok?: true, result: %{quarantined: n}} -> %>
              <span class="text-red-600 dark:text-red-400 font-mono">{n}</span>
              <span class="text-red-600 dark:text-red-400">quarantined — investigate</span>
            <% _ -> %>
              <span class="text-zinc-400">loading…</span>
          <% end %>
        </.drilldown_card>

        <.drilldown_card
          href="/system/events"
          title="Events"
          subtitle="Live PubSub timeline — paste into any bug report"
        >
          <span class="text-zinc-400">tap + filter</span>
        </.drilldown_card>

        <.drilldown_card
          href="/system/sagas"
          title="Sagas"
          subtitle="Multi-step ops — succeeded / rolled back / failed"
        >
          <%= case @counts do %>
            <% %{ok?: true, result: %{sagas: %{rollback_failed: n}}} when n > 0 -> %>
              <span class="text-red-600 dark:text-red-400 font-mono">{n}</span>
              <span class="text-red-600 dark:text-red-400">rollbacks failed — investigate</span>
            <% %{ok?: true, result: %{sagas: %{total: 0}}} -> %>
              <span class="text-zinc-400">none recorded</span>
            <% %{ok?: true, result: %{sagas: %{total: t, succeeded: s}}} -> %>
              <span class="font-mono">{s}</span>/<span class="font-mono">{t}</span> succeeded
            <% _ -> %>
              <span class="text-zinc-400">loading…</span>
          <% end %>
        </.drilldown_card>

        <.drilldown_card
          href="/system/orphans"
          title="Orphans"
          subtitle="Tracked OS/OTP resources with live owner pid"
        >
          <%= case @counts do %>
            <% %{ok?: true, result: %{resources: %{stale: stale}}} when stale > 0 -> %>
              <span class="text-red-600 dark:text-red-400 font-mono">{stale}</span>
              <span class="text-red-600 dark:text-red-400">stale — cleanup leak</span>
            <% %{ok?: true, result: %{resources: %{total: 0}}} -> %>
              <span class="text-zinc-400">none tracked</span>
            <% %{ok?: true, result: %{resources: %{total: t}}} -> %>
              <span class="font-mono">{t}</span> tracked
            <% _ -> %>
              <span class="text-zinc-400">loading…</span>
          <% end %>
        </.drilldown_card>

        <.drilldown_card
          href="/system/recovery"
          title="Recovery"
          subtitle="Per-workspace snapshot health; bounded boot time"
        >
          <%= case @counts do %>
            <% %{ok?: true, result: %{recovery: %{failed: n}}} when n > 0 -> %>
              <span class="text-red-600 dark:text-red-400 font-mono">{n}</span>
              <span class="text-red-600 dark:text-red-400">failed — investigate</span>
            <% %{ok?: true, result: %{recovery: %{total: 0}}} -> %>
              <span class="text-zinc-400">none running</span>
            <% %{ok?: true, result: %{recovery: %{total: t}}} -> %>
              <span class="font-mono">{t}</span> workspaces checkpointed
            <% _ -> %>
              <span class="text-zinc-400">loading…</span>
          <% end %>
        </.drilldown_card>

        <.drilldown_card
          href="/system/secrets"
          title="Secrets"
          subtitle="Named credentials agents fetch at runtime"
        >
          <span class="text-zinc-400">view · add · rotate</span>
        </.drilldown_card>
      </div>
    </section>
    """
  end

  attr :href, :string, required: true
  attr :title, :string, required: true
  attr :subtitle, :string, required: true
  slot :inner_block, required: true

  defp drilldown_card(assigns) do
    ~H"""
    <.link
      navigate={@href}
      class="block rounded-sm border border-zinc-200 dark:border-zinc-700/80 bg-zinc-50 dark:bg-zinc-800/50 p-4 hover:border-violet-400 dark:hover:border-violet-500 hover:bg-zinc-100 dark:hover:bg-zinc-800 transition-colors"
    >
      <div class="flex items-center justify-between">
        <div>
          <div class="text-body font-semibold">{@title}</div>
          <div class="text-meta text-zinc-500 dark:text-zinc-400 mt-0.5">{@subtitle}</div>
          <div class="text-meta text-zinc-600 dark:text-zinc-400 font-mono mt-2">
            {render_slot(@inner_block)}
          </div>
        </div>
        <svg
          xmlns="http://www.w3.org/2000/svg"
          viewBox="0 0 20 20"
          fill="currentColor"
          class="w-4 h-4 text-zinc-400"
        >
          <path
            fill-rule="evenodd"
            d="M7.21 14.77a.75.75 0 0 1 .02-1.06L11.168 10 7.23 6.29a.75.75 0 1 1 1.04-1.08l4.5 4.25a.75.75 0 0 1 0 1.08l-4.5 4.25a.75.75 0 0 1-1.06-.02Z"
            clip-rule="evenodd"
          />
        </svg>
      </div>
    </.link>
    """
  end

  # --- Recent Logs ---

  defp log_section(assigns) do
    ~H"""
    <section>
      <h2 class="text-body font-semibold uppercase tracking-wider text-zinc-500 dark:text-zinc-400 mb-3">
        Recent Logs <span class="text-zinc-400 font-normal">(last 20)</span>
      </h2>
      <div class="rounded-sm border border-zinc-200 dark:border-zinc-700/80 bg-zinc-50 dark:bg-zinc-800/50 overflow-hidden">
        <div class="px-4 py-3 text-meta font-mono text-zinc-600 dark:text-zinc-400 space-y-0.5 max-h-64 overflow-y-auto">
          <div :if={@logs == []} class="text-zinc-400">no recent logs</div>
          <div :for={entry <- @logs}>
            <span class={log_level_class(entry.level)}>[{entry.level}]</span>
            <span>{entry.message}</span>
          </div>
        </div>
      </div>
    </section>
    """
  end
end
