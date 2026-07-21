defmodule LoopyardWeb.SystemOrphansLive do
  @moduledoc """
  Lists every tracked `Loopyard.Resources` entry, grouped by owner.

  Move #7b in `plans/coordination-hardening.md`. The janitor releases
  every resource when its owner goes DOWN, so in steady state every
  entry here has `owner_alive? = true`. Any `owner_alive? = false`
  row is an invariant violation — the monitor-driven cleanup should
  have fired already — and gets a red "stale" badge so operators
  notice.

  Refreshes every 2s. Refresh is cheap (single ETS tab2list).
  """
  use LoopyardWeb, :live_view
  use LoopyardWeb.IExAware

  alias Loopyard.Resources

  @refresh_ms 2_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Process.send_after(self(), :refresh, @refresh_ms)
    end

    {:ok,
     socket
     |> assign_iex()
     |> assign_entries()}
  end

  defp assign_iex(socket) do
    if connected?(socket),
      do: subscribe_iex(socket),
      else: assign(socket, :iex_session, %{level: nil})
  end

  defp assign_entries(socket) do
    entries = Resources.all()

    grouped =
      entries
      |> Enum.group_by(& &1.owner)
      |> Enum.map(fn {owner, resources} ->
        %{
          owner: owner,
          owner_alive?: Enum.any?(resources, & &1.owner_alive?),
          resources: Enum.sort_by(resources, & &1.kind)
        }
      end)
      |> Enum.sort_by(fn g ->
        # Dead-owner groups float to the top — they're the invariant
        # violation the page is designed to surface.
        {if(g.owner_alive?, do: 1, else: 0), inspect(g.owner)}
      end)

    stale_count = Enum.count(entries, &(not &1.owner_alive?))

    socket
    |> assign(:groups, grouped)
    |> assign(:total, length(entries))
    |> assign(:stale_count, stale_count)
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, assign_entries(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <.page_shell
      breadcrumbs={[{"Loopyard", "/"}, {"System", "/system"}, {"Orphans", nil}]}
      iex_session={@iex_session}
      max_width={:xl}
      flash={@flash}
    >
      <div class="space-y-6">
        <section>
          <div class="flex items-baseline justify-between mb-3">
            <h2 class="text-sm font-semibold uppercase tracking-wider text-zinc-500 dark:text-zinc-400">
              Tracked resources <span class="text-zinc-400 font-normal">({@total})</span>
            </h2>
            <div :if={@stale_count > 0} class="text-xs font-medium text-red-600 dark:text-red-400">
              {@stale_count} stale — owner DOWN cleanup leak?
            </div>
          </div>

          <p class="text-xs text-zinc-500 dark:text-zinc-400 mb-4">
            Every resource tracked via <code class="font-mono">Loopyard.Resources.track/4</code>.
            Each owner pid owns one or more resources; when an owner goes DOWN the janitor
            releases them automatically. Any row with a red "stale" badge means the janitor
            did NOT fire for an already-dead owner — a bug in the ownership declarations
            or monitor setup.
          </p>

          <%= if @groups == [] do %>
            <div class="text-sm text-zinc-500 dark:text-zinc-400 italic">
              No tracked resources. Every subsystem is either not yet migrated or has no
              live allocations.
            </div>
          <% else %>
            <div class="space-y-4">
              <.owner_group :for={group <- @groups} group={group} />
            </div>
          <% end %>
        </section>

        <section>
          <h3 class="text-xs font-semibold uppercase tracking-wider text-zinc-500 dark:text-zinc-400 mb-2">
            Coverage
          </h3>
          <p class="text-xs text-zinc-500 dark:text-zinc-400 mb-2">
            In-scope resources migrated to the janitor:
          </p>
          <ul class="text-xs text-zinc-600 dark:text-zinc-300 list-disc list-inside space-y-1">
            <li>
              <code class="font-mono">:port_binding</code>
              — PortRegistry, owned by WorkspaceGroup supervisor
            </li>
          </ul>
          <p class="text-xs text-zinc-500 dark:text-zinc-400 mt-3">
            Non-migrated owner-resource pairs (by design — see
            <code class="font-mono">Loopyard.Resources</code>
            @moduledoc):
          </p>
          <ul class="text-xs text-zinc-600 dark:text-zinc-300 list-disc list-inside space-y-1">
            <li>Docker containers — lifecycle tied to compose up/down</li>
            <li>Claude CLI port — linked to ChatAgent GenServer via BEAM Port semantics</li>
            <li>Mutagen sync sessions — session OUTLIVES GenServer restart by design</li>
            <li>
              Short-lived <code class="font-mono">Port.open</code> CLI calls — die with owning process
            </li>
          </ul>
        </section>
      </div>
    </.page_shell>
    """
  end

  attr :group, :map, required: true

  defp owner_group(assigns) do
    ~H"""
    <div class={owner_group_class(@group.owner_alive?)}>
      <div class="flex items-center justify-between px-3 py-2 border-b border-zinc-200 dark:border-zinc-700/50 bg-zinc-100/50 dark:bg-zinc-800/30">
        <div class="flex items-center gap-2">
          <div class={"w-2 h-2 rounded-full " <> if(@group.owner_alive?, do: "bg-emerald-500", else: "bg-red-500 animate-pulse")}>
          </div>
          <div class="text-xs font-mono">{inspect(@group.owner)}</div>
          <div
            :if={not @group.owner_alive?}
            class="text-[10px] uppercase font-semibold text-red-600 dark:text-red-400 tracking-wider"
          >
            stale — owner DOWN
          </div>
        </div>
        <div class="text-[10px] uppercase tracking-wider text-zinc-500 dark:text-zinc-400">
          {length(@group.resources)} {if length(@group.resources) == 1,
            do: "resource",
            else: "resources"}
        </div>
      </div>
      <table class="w-full text-xs">
        <thead>
          <tr class="text-zinc-500 dark:text-zinc-400 text-left">
            <th class="px-3 py-1.5 font-medium">Kind</th>
            <th class="px-3 py-1.5 font-medium">ID</th>
            <th class="px-3 py-1.5 font-medium">Tracked at</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={r <- @group.resources} class="border-t border-zinc-200 dark:border-zinc-700/30">
            <td class="px-3 py-1.5 font-mono font-semibold">{r.kind}</td>
            <td class="px-3 py-1.5 font-mono text-zinc-600 dark:text-zinc-400 break-all">
              {inspect(r.id, limit: :infinity, printable_limit: :infinity)}
            </td>
            <td class="px-3 py-1.5 text-zinc-500 font-mono">{format_ts(r.inserted_at_us)}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp owner_group_class(true),
    do: "rounded-lg border border-zinc-200 dark:border-zinc-700/80 overflow-hidden"

  defp owner_group_class(false),
    do:
      "rounded-lg border-2 border-red-300 dark:border-red-800 overflow-hidden bg-red-50/30 dark:bg-red-900/10"

  # Monotonic microseconds → human-readable relative string.
  # Monotonic time has no epoch anchor; compare to current monotonic.
  defp format_ts(ts_us) when is_integer(ts_us) do
    now_us = System.monotonic_time(:microsecond)
    age_ms = max(0, div(now_us - ts_us, 1_000))

    cond do
      age_ms < 1_000 -> "#{age_ms}ms ago"
      age_ms < 60_000 -> "#{div(age_ms, 1_000)}s ago"
      age_ms < 3_600_000 -> "#{div(age_ms, 60_000)}m ago"
      true -> "#{div(age_ms, 3_600_000)}h ago"
    end
  end

  defp format_ts(_), do: "—"
end
