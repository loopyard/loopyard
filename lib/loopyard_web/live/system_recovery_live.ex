defmodule LoopyardWeb.SystemRecoveryLive do
  @moduledoc """
  Per-workspace checkpoint health for move #8 in
  `plans/coordination-hardening.md`.

  Shows, for every running Checkpointer:

  * Last snapshot timestamp + status (ok / failed).
  * Current log size and records accumulated since the last
  snapshot — the two quantities that bound recovery time.
  * Presence / size of the `.prev` backup used by
  `AgentLog.replay_with_fallback/1` on boot corruption.

  Refreshes every 2s.
  """
  use LoopyardWeb, :live_view
  use LoopyardWeb.IExAware

  alias Loopyard.AgentLog.Checkpointer

  @refresh_ms 2_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @refresh_ms)

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
    entries =
      Checkpointer.list_all()
      |> Enum.sort_by(fn e ->
        # Failed / never-snapshotted entries float to the top, then
        # stale (long time since last snapshot), then alphabetical.
        {failure_priority(e.last_result), stale_priority(e.last_checkpoint_at),
         e.workspace_id || ""}
      end)

    total = length(entries)
    failed_count = Enum.count(entries, &failed?/1)

    assign(socket,
      entries: entries,
      total: total,
      failed_count: failed_count
    )
  end

  defp failed?(%{last_result: {:error, _}}), do: true
  defp failed?(_), do: false

  defp failure_priority({:error, _}), do: 0
  defp failure_priority(_), do: 1

  defp stale_priority(nil), do: 0
  defp stale_priority(_), do: 1

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
      mode={:system}
      breadcrumbs={[{"Loopyard", "/"}, {"System", "/system"}, {"Recovery", nil}]}
      iex_session={@iex_session}
      max_width={:xl}
      flash={@flash}
    >
      <div class="space-y-6">
        <section>
          <div class="flex items-baseline justify-between mb-3">
            <h2 class="text-sm font-semibold uppercase tracking-wider text-zinc-500 dark:text-zinc-400">
              Checkpoint health <span class="text-zinc-400 font-normal">({@total} workspaces)</span>
            </h2>
            <div
              :if={@failed_count > 0}
              class="text-xs font-medium text-red-600 dark:text-red-400"
            >
              {@failed_count} failed last checkpoint — investigate
            </div>
          </div>

          <p class="text-xs text-zinc-500 dark:text-zinc-400 mb-4">
            Each row is one workspace's agent-log checkpointer. Snapshots run periodically
            (or after N records are written) and rewrite the log to a minimal form, keeping
            the prior version as <code class="font-mono">.prev</code> so a corrupt primary
            can fall back cleanly on boot. Long gaps between snapshots + large current log
            sizes mean a slow recovery if the BEAM dies now.
          </p>

          <.recovery_table entries={@entries} />
        </section>
      </div>
    </.page_shell>
    """
  end

  attr :entries, :list, required: true

  defp recovery_table(assigns) do
    ~H"""
    <%= if @entries == [] do %>
      <div class="text-sm text-zinc-500 dark:text-zinc-400 italic py-8 text-center">
        No checkpointers running. Start a workspace to populate this page.
      </div>
    <% else %>
      <div class="overflow-x-auto">
        <table class="min-w-full text-xs font-mono">
          <thead class="text-zinc-500 dark:text-zinc-400">
            <tr class="border-b border-zinc-200 dark:border-zinc-700/80">
              <th class="text-left py-2 pr-4 font-semibold">Workspace</th>
              <th class="text-left py-2 pr-4 font-semibold">Last snapshot</th>
              <th class="text-right py-2 pr-4 font-semibold">Records since</th>
              <th class="text-right py-2 pr-4 font-semibold">Primary</th>
              <th class="text-right py-2 pr-4 font-semibold">.prev</th>
              <th class="text-left py-2 pr-4 font-semibold">Status</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={e <- @entries} class="border-b border-zinc-100 dark:border-zinc-800/50">
              <td class="py-2 pr-4 text-violet-700 dark:text-violet-400 font-semibold">
                {short_id(e.workspace_id)}
              </td>
              <td class="py-2 pr-4 text-zinc-600 dark:text-zinc-400">
                {format_timestamp(e.last_checkpoint_at)}
              </td>
              <td class="py-2 pr-4 text-right text-zinc-700 dark:text-zinc-300">
                {e.records_since_checkpoint}
              </td>
              <td class="py-2 pr-4 text-right text-zinc-700 dark:text-zinc-300">
                {format_bytes(e.current_log_bytes)}
              </td>
              <td class="py-2 pr-4 text-right text-zinc-600 dark:text-zinc-400">
                {format_bytes(e.prev_log_bytes)}
              </td>
              <td class="py-2 pr-4">
                <.status_badge result={e.last_result} />
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    <% end %>
    """
  end

  attr :result, :any, required: true

  defp status_badge(%{result: nil} = assigns) do
    ~H"""
    <span class="section-label rounded-full bg-zinc-200 dark:bg-zinc-700 text-zinc-700 dark:text-zinc-300 px-2 py-0.5">
      never
    </span>
    """
  end

  defp status_badge(%{result: {:ok, _}} = assigns) do
    ~H"""
    <span class="section-label rounded-full bg-emerald-100 dark:bg-emerald-900/30 text-emerald-700 dark:text-emerald-300 px-2 py-0.5">
      ok
    </span>
    """
  end

  defp status_badge(%{result: {:error, reason}} = assigns) do
    assigns = assign(assigns, :reason, inspect(reason))

    ~H"""
    <span
      title={@reason}
      class="section-label rounded-full bg-red-100 dark:bg-red-900/30 text-red-700 dark:text-red-300 px-2 py-0.5"
    >
      failed
    </span>
    """
  end

  defp short_id(nil), do: "—"
  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 12)
  defp short_id(other), do: inspect(other)

  defp format_timestamp(nil), do: "never"

  defp format_timestamp(%DateTime{} = dt) do
    ago_seconds = DateTime.diff(DateTime.utc_now(), dt, :second)
    "#{Calendar.strftime(dt, "%H:%M:%S")} (#{format_ago(ago_seconds)})"
  end

  defp format_ago(s) when s < 60, do: "#{s}s ago"
  defp format_ago(s) when s < 3600, do: "#{div(s, 60)}m ago"
  defp format_ago(s), do: "#{div(s, 3600)}h ago"
end
