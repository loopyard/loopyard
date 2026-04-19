defmodule BoomLooperWeb.SystemSagasLive do
  @moduledoc """
  Recent `BoomLooper.Saga` runs — which steps succeeded, which failed,
  whether rollback completed cleanly. Drives move #7a's observability
  guarantee: every partial-success state that would have existed in
  the old code is visible here as a rolled-back saga.

  Red alert: any saga with `:rollback_failed` status means we couldn't
  fully revert — external state may be inconsistent. Operator should
  investigate before trusting the workspace.
  """
  use BoomLooperWeb, :live_view
  use BoomLooperWeb.IExAware

  alias BoomLooper.Saga.Recorder

  @refresh_ms 1_000

  @impl true
  def mount(params, _session, socket) do
    saga_filter = Map.get(params, "saga")

    socket =
      socket
      |> assign_iex()
      |> assign(:saga_filter, saga_filter)
      |> assign(:sagas, load_sagas(saga_filter))
      |> assign(:summary, Recorder.summary())

    if connected?(socket), do: schedule_refresh()
    {:ok, socket}
  end

  defp assign_iex(socket) do
    if connected?(socket), do: subscribe_iex(socket), else: assign(socket, :iex_session, %{level: nil})
  end

  @impl true
  def handle_params(params, _url, socket) do
    saga_filter = Map.get(params, "saga")

    {:noreply,
     socket
     |> assign(:saga_filter, saga_filter)
     |> assign(:sagas, load_sagas(saga_filter))
     |> assign(:summary, Recorder.summary())}
  end

  @impl true
  def handle_info(:refresh, socket) do
    schedule_refresh()

    {:noreply,
     socket
     |> assign(:sagas, load_sagas(socket.assigns.saga_filter))
     |> assign(:summary, Recorder.summary())}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp schedule_refresh, do: Process.send_after(self(), :refresh, @refresh_ms)

  defp load_sagas(nil), do: Recorder.recent(limit: 100)
  defp load_sagas(saga), do: Recorder.recent(saga: String.to_existing_atom(saga), limit: 100)

  defp saga_names(sagas), do: sagas |> Enum.map(& &1.saga) |> Enum.uniq() |> Enum.sort()

  @impl true
  def render(assigns) do
    ~H"""
    <.page_shell
      breadcrumbs={[{"Boom Looper", "/"}, {"System", "/system"}, {"Sagas", nil}]}
      iex_session={@iex_session}
      max_width={:xl}
      flash={@flash}
    >
      <div class="space-y-6">
        <section>
          <div class="flex items-baseline justify-between mb-3">
            <h2 class="text-sm font-semibold uppercase tracking-wider text-zinc-500 dark:text-zinc-400">
              Sagas
              <span class="text-zinc-400 font-normal">(last 100 multi-step operations; refreshes every 1s)</span>
            </h2>
          </div>

          <p class="text-xs text-zinc-500 dark:text-zinc-400 mb-4">
            Every `BoomLooper.Saga.run/2` call is recorded here. Each saga is a multi-step
            operation (start workspace, boot agent, etc.) that either fully succeeded or
            fully rolled back. A saga in <span class="text-red-600 dark:text-red-400 font-semibold">rollback_failed</span>
            state could not fully revert — external state may be inconsistent and the
            operator should investigate.
          </p>

          <.summary_cards summary={@summary} />
          <.filter_bar sagas={@sagas} current={@saga_filter} all_names={saga_names(@sagas)} />
          <.saga_table sagas={@sagas} />
        </section>
      </div>
    </.page_shell>
    """
  end

  defp summary_cards(assigns) do
    ~H"""
    <div class="grid grid-cols-2 md:grid-cols-5 gap-2 mb-4">
      <.summary_card label="Total" value={@summary.total} tone={:neutral} />
      <.summary_card label="Succeeded" value={@summary.succeeded} tone={:ok} />
      <.summary_card label="Rolled back" value={@summary.rolled_back} tone={:warn} />
      <.summary_card label="Rollback failed" value={@summary.rollback_failed} tone={:alert} />
      <.summary_card label="In flight" value={@summary.in_flight} tone={:neutral} />
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :tone, :atom, required: true

  defp summary_card(assigns) do
    ~H"""
    <div class={summary_card_class(@tone)}>
      <div class="text-[10px] uppercase tracking-wider text-zinc-500 dark:text-zinc-400">{@label}</div>
      <div class="text-lg font-mono font-semibold mt-0.5">{@value}</div>
    </div>
    """
  end

  defp summary_card_class(:neutral),
    do:
      "rounded-lg border border-zinc-200 dark:border-zinc-700/80 bg-zinc-50 dark:bg-zinc-800/50 px-3 py-2"

  defp summary_card_class(:ok),
    do:
      "rounded-lg border border-emerald-200 dark:border-emerald-900/50 bg-emerald-50 dark:bg-emerald-900/10 px-3 py-2"

  defp summary_card_class(:warn),
    do:
      "rounded-lg border border-amber-200 dark:border-amber-900/50 bg-amber-50 dark:bg-amber-900/10 px-3 py-2"

  defp summary_card_class(:alert),
    do:
      "rounded-lg border border-red-300 dark:border-red-800 bg-red-50 dark:bg-red-900/20 px-3 py-2"

  defp filter_bar(assigns) do
    ~H"""
    <div class="flex flex-wrap gap-2 mb-4">
      <.link patch={~p"/system/sagas"} class={filter_pill_class(@current == nil)}>
        All
      </.link>
      <%= for name <- @all_names do %>
        <.link
          patch={~p"/system/sagas?saga=#{name}"}
          class={filter_pill_class(@current == Atom.to_string(name))}
        >
          {name}
        </.link>
      <% end %>
    </div>
    """
  end

  defp filter_pill_class(true),
    do: "rounded-full px-3 py-1 text-xs font-medium bg-violet-600 text-white"

  defp filter_pill_class(false),
    do:
      "rounded-full px-3 py-1 text-xs font-medium border border-zinc-300 dark:border-zinc-700 text-zinc-600 dark:text-zinc-400 hover:border-violet-400 dark:hover:border-violet-500"

  defp saga_table(assigns) do
    ~H"""
    <%= if @sagas == [] do %>
      <div class="text-sm text-zinc-400 dark:text-zinc-500 italic py-8 text-center">
        No sagas recorded yet. Start a workspace or boot an agent to populate this page.
      </div>
    <% else %>
      <div class="space-y-2">
        <.saga_row :for={saga <- @sagas} saga={saga} />
      </div>
    <% end %>
    """
  end

  attr :saga, :map, required: true

  defp saga_row(assigns) do
    ~H"""
    <details class={"rounded-lg border overflow-hidden " <> row_border_class(@saga.status)}>
      <summary class="px-3 py-2 cursor-pointer flex items-center gap-3">
        <span class={status_badge_class(@saga.status)}>
          {humanize_status(@saga.status)}
        </span>
        <span class="text-xs font-mono font-semibold text-violet-700 dark:text-violet-400">
          {@saga.saga}
        </span>
        <span class="text-[11px] font-mono text-zinc-500">
          {Calendar.strftime(@saga.started_at, "%H:%M:%S")}
        </span>
        <span class="text-[11px] text-zinc-500">
          {length(@saga.completed_steps)}/{@saga.step_count} steps
        </span>
        <span :if={@saga.failed_step} class="text-[11px] text-red-600 dark:text-red-400 font-mono">
          failed at {@saga.failed_step}
        </span>
        <span :if={meta_preview(@saga.metadata)} class="text-[11px] font-mono text-zinc-400 ml-auto">
          {meta_preview(@saga.metadata)}
        </span>
      </summary>

      <div class="px-3 py-2 bg-zinc-50 dark:bg-zinc-900/50 border-t border-zinc-200 dark:border-zinc-700/50">
        <.step_list steps={@saga.completed_steps} rolled_back={@saga.rolled_back_steps} failed_rollbacks={@saga.failed_rollbacks} />

        <div :if={@saga.failure_reason} class="mt-2 text-[11px] font-mono text-red-600 dark:text-red-400">
          reason: {@saga.failure_reason}
        </div>

        <div :if={@saga.failed_rollbacks != []} class="mt-2">
          <div class="text-[10px] uppercase tracking-wider text-red-600 dark:text-red-400 font-semibold mb-1">
            Failed rollbacks
          </div>
          <ul class="text-[11px] font-mono text-red-700 dark:text-red-400 space-y-0.5">
            <%= for {step, reason} <- @saga.failed_rollbacks do %>
              <li>{step}: {reason}</li>
            <% end %>
          </ul>
        </div>

        <div :if={map_size(@saga.metadata) > 0} class="mt-2 text-[11px] font-mono text-zinc-500">
          metadata: {inspect(@saga.metadata)}
        </div>
      </div>
    </details>
    """
  end

  attr :steps, :list, required: true
  attr :rolled_back, :list, required: true
  attr :failed_rollbacks, :list, required: true

  defp step_list(assigns) do
    ~H"""
    <ol class="text-[11px] font-mono space-y-1">
      <li :for={step <- @steps} class="flex items-center gap-2">
        <span class={"w-1.5 h-1.5 rounded-full " <> step_dot_class(step.status)}></span>
        <span class={step_name_class(step.status)}>{step.name}</span>
        <span :if={step.status == :failed} class="text-red-500 text-[10px]">
          — failed: {step[:reason]}
        </span>
        <span :if={step.name in @rolled_back} class="text-amber-600 dark:text-amber-400 text-[10px]">
          — rolled back
        </span>
        <span :if={rollback_failed?(step.name, @failed_rollbacks)} class="text-red-600 dark:text-red-400 text-[10px] font-semibold">
          — rollback failed
        </span>
      </li>
    </ol>
    """
  end

  defp rollback_failed?(step_name, failed_rollbacks) do
    Enum.any?(failed_rollbacks, fn {name, _reason} -> name == step_name end)
  end

  defp row_border_class(:in_flight),
    do: "border-zinc-200 dark:border-zinc-700/80 bg-zinc-50 dark:bg-zinc-800/50"

  defp row_border_class(:succeeded),
    do: "border-emerald-200 dark:border-emerald-900/50 bg-emerald-50/50 dark:bg-emerald-900/10"

  defp row_border_class(:rolled_back),
    do: "border-amber-200 dark:border-amber-900/50 bg-amber-50/50 dark:bg-amber-900/10"

  defp row_border_class(:rollback_failed),
    do: "border-red-300 dark:border-red-800 bg-red-50 dark:bg-red-900/20"

  defp row_border_class(_),
    do: "border-zinc-200 dark:border-zinc-700/80"

  defp status_badge_class(:in_flight),
    do:
      "rounded-full bg-blue-100 dark:bg-blue-900/30 text-blue-700 dark:text-blue-300 text-[10px] font-semibold uppercase tracking-wider px-2 py-0.5"

  defp status_badge_class(:succeeded),
    do:
      "rounded-full bg-emerald-100 dark:bg-emerald-900/30 text-emerald-700 dark:text-emerald-300 text-[10px] font-semibold uppercase tracking-wider px-2 py-0.5"

  defp status_badge_class(:rolled_back),
    do:
      "rounded-full bg-amber-100 dark:bg-amber-900/30 text-amber-700 dark:text-amber-300 text-[10px] font-semibold uppercase tracking-wider px-2 py-0.5"

  defp status_badge_class(:rollback_failed),
    do:
      "rounded-full bg-red-200 dark:bg-red-900/50 text-red-700 dark:text-red-300 text-[10px] font-semibold uppercase tracking-wider px-2 py-0.5 animate-pulse"

  defp status_badge_class(_),
    do:
      "rounded-full bg-zinc-200 dark:bg-zinc-700 text-zinc-700 dark:text-zinc-300 text-[10px] font-semibold uppercase tracking-wider px-2 py-0.5"

  defp humanize_status(:in_flight), do: "in flight"
  defp humanize_status(:succeeded), do: "succeeded"
  defp humanize_status(:rolled_back), do: "rolled back"
  defp humanize_status(:rollback_failed), do: "rollback failed"
  defp humanize_status(other), do: to_string(other)

  defp step_dot_class(:succeeded), do: "bg-emerald-500"
  defp step_dot_class(:failed), do: "bg-red-500"
  defp step_dot_class(_), do: "bg-zinc-400"

  defp step_name_class(:succeeded), do: "text-zinc-700 dark:text-zinc-300"
  defp step_name_class(:failed), do: "text-red-700 dark:text-red-400 font-semibold"
  defp step_name_class(_), do: "text-zinc-600 dark:text-zinc-400"

  defp meta_preview(metadata) when map_size(metadata) == 0, do: nil

  defp meta_preview(metadata) do
    metadata
    |> Enum.map(fn {k, v} -> "#{k}=#{inspect(v)}" end)
    |> Enum.join(" ")
  end
end
