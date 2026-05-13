defmodule LoopyardWeb.SystemEventsLive do
  @moduledoc """
  Live timeline of every Loopyard PubSub broadcast on the global
  topics tracked by `Loopyard.Events.Tap`. Drop this URL into any
  bug report — the 30s-window view makes "what happened just before
  the UI did X" answerable without reproduction.

  Move #7 of plans/coordination-hardening.md.
  """
  use LoopyardWeb, :live_view
  use LoopyardWeb.IExAware

  alias Loopyard.Events.Tap

  # Refresh cadence. The tap itself is a live subscriber; the LV
  # re-reads the buffer on a short timer to roll the timeline forward
  # without flooding assigns on every broadcast (which could be
  # dozens per second).
  @refresh_ms 500

  @impl true
  def mount(params, _session, socket) do
    topic_filter = Map.get(params, "topic")

    socket =
      socket
      |> assign_iex()
      |> assign(:topic_filter, topic_filter)
      |> assign(:topics, Tap.topics())
      |> assign(:counts, Tap.topic_counts())
      |> assign(:events, load_events(topic_filter))

    if connected?(socket), do: schedule_refresh()
    {:ok, socket}
  end

  defp assign_iex(socket) do
    if connected?(socket),
      do: subscribe_iex(socket),
      else: assign(socket, :iex_session, %{level: nil})
  end

  @impl true
  def handle_params(params, _url, socket) do
    topic_filter = Map.get(params, "topic")

    {:noreply,
     socket
     |> assign(:topic_filter, topic_filter)
     |> assign(:events, load_events(topic_filter))
     |> assign(:counts, Tap.topic_counts())}
  end

  @impl true
  def handle_info(:refresh, socket) do
    schedule_refresh()

    {:noreply,
     socket
     |> assign(:events, load_events(socket.assigns.topic_filter))
     |> assign(:counts, Tap.topic_counts())}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp schedule_refresh, do: Process.send_after(self(), :refresh, @refresh_ms)

  defp load_events(nil), do: Tap.recent(limit: 200)
  defp load_events(topic), do: Tap.recent(topic: topic, limit: 200)

  @impl true
  def render(assigns) do
    ~H"""
    <.page_shell
      breadcrumbs={[{"Loopyard", "/"}, {"System", "/system"}, {"Events", nil}]}
      iex_session={@iex_session}
      max_width={:xl}
      flash={@flash}
    >
      <div class="space-y-6">
        <section>
          <div class="flex items-baseline justify-between mb-3">
            <h2 class="text-sm font-semibold uppercase tracking-wider text-zinc-500 dark:text-zinc-400">
              Events tap
              <span class="text-zinc-400 font-normal">
                (last 500 broadcasts; refreshes every 500ms)
              </span>
            </h2>
          </div>

          <p class="text-xs text-zinc-500 dark:text-zinc-400 mb-4">
            Ring buffer of every Loopyard-global PubSub broadcast with timestamp + topic
            + event tag + payload preview. Filter by topic below. Per-agent and per-workspace
            topics (<code class="font-mono text-[11px]">chat_agent:{"{id}"}</code>, <code class="font-mono text-[11px]">source_sync:{"{id}"}</code>) are not
            captured here — they multiply with workload and belong on each agent's own page.
          </p>

          <.topic_filter_bar counts={@counts} current={@topic_filter} />

          <.event_table events={@events} />
        </section>
      </div>
    </.page_shell>
    """
  end

  defp topic_filter_bar(assigns) do
    ~H"""
    <div class="flex flex-wrap gap-2 mb-4">
      <.link
        patch={~p"/system/events"}
        class={topic_pill_class(@current == nil)}
      >
        All
      </.link>
      <%= for {topic, count} <- Enum.sort(@counts) do %>
        <.link
          patch={~p"/system/events?topic=#{topic}"}
          class={topic_pill_class(@current == topic)}
        >
          {topic}
          <span class="font-mono text-[10px] opacity-70 ml-1">{count}</span>
        </.link>
      <% end %>
    </div>
    """
  end

  defp topic_pill_class(true) do
    "rounded-full px-3 py-1 text-xs font-medium bg-violet-600 text-white"
  end

  defp topic_pill_class(false) do
    "rounded-full px-3 py-1 text-xs font-medium border border-zinc-300 dark:border-zinc-700 text-zinc-600 dark:text-zinc-400 hover:border-violet-400 dark:hover:border-violet-500"
  end

  defp event_table(assigns) do
    ~H"""
    <%= if @events == [] do %>
      <div class="text-sm text-zinc-400 dark:text-zinc-500 italic py-8 text-center">
        No events captured yet. Broadcasts will appear here in real time.
      </div>
    <% else %>
      <div class="rounded-lg border border-zinc-200 dark:border-zinc-700/80 overflow-hidden">
        <table class="w-full text-xs">
          <thead>
            <tr class="bg-zinc-100 dark:bg-zinc-800 text-zinc-500 dark:text-zinc-400 text-left">
              <th class="px-3 py-2 font-medium w-40">Time</th>
              <th class="px-3 py-2 font-medium w-36">Topic</th>
              <th class="px-3 py-2 font-medium w-56">Event</th>
              <th class="px-3 py-2 font-medium">Payload</th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={e <- @events}
              class="border-t border-zinc-200 dark:border-zinc-700/50 hover:bg-zinc-50 dark:hover:bg-zinc-800/40"
            >
              <td class="px-3 py-2 font-mono text-zinc-500 whitespace-nowrap">
                {Calendar.strftime(e.inserted_at_utc, "%H:%M:%S.") <>
                  to_string(:io_lib.format("~3..0B", [elem(e.inserted_at_utc.microsecond, 0) |> div(1000)]))}
              </td>
              <td class="px-3 py-2 font-mono text-zinc-600 dark:text-zinc-400">{e.topic}</td>
              <td class="px-3 py-2 font-mono text-violet-700 dark:text-violet-400 font-semibold">
                {inspect(e.tag)}
              </td>
              <td
                class="px-3 py-2 font-mono text-zinc-500 text-[11px] truncate max-w-[600px]"
                title={e.payload}
              >
                {e.payload}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    <% end %>
    """
  end
end
