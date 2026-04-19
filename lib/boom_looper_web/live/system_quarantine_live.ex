defmodule BoomLooperWeb.SystemQuarantineLive do
  @moduledoc """
  Lists every quarantined ChatAgent across every workspace. Operators
  click "Release" to un-quarantine and respawn. Subscribes to the
  chat_agents topic so the list updates live as agents enter or
  leave quarantine.

  Part of the coordination-hardening plan Move #10. The quarantine
  mechanism itself lives in `BoomLooper.ChatAgent.RestartController`;
  this LV is the operator-facing surface.
  """
  use BoomLooperWeb, :live_view
  use BoomLooperWeb.IExAware

  alias BoomLooper.ChatAgent.RestartController

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(BoomLooper.PubSub, "chat_agents")
    end

    {:ok,
     socket
     |> assign_iex()
     |> assign(:quarantined, RestartController.list_quarantined())}
  end

  defp assign_iex(socket) do
    if connected?(socket), do: subscribe_iex(socket), else: assign(socket, :iex_session, %{level: nil})
  end

  # Any quarantine-related event → refresh the list from ETS.
  # Notification-only pattern (re-read authoritative state rather than
  # trust the broadcast payload). Same shape as the other /system LVs.
  @impl true
  def handle_info({:chat_agent_quarantined, _id, _summary}, socket) do
    {:noreply, assign(socket, :quarantined, RestartController.list_quarantined())}
  end

  def handle_info({:chat_agent_released, _id}, socket) do
    {:noreply, assign(socket, :quarantined, RestartController.list_quarantined())}
  end

  # Other agent events are ignored here — the /system/quarantine page
  # only cares about the quarantine-specific transitions.
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("release", %{"id" => id}, socket) do
    RestartController.release(id)

    {:noreply,
     socket
     |> put_flash(:info, "Released #{id} from quarantine.")
     |> assign(:quarantined, RestartController.list_quarantined())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_shell
      breadcrumbs={[{"Boom Looper", "/"}, {"System", "/system"}, {"Quarantine", nil}]}
      iex_session={@iex_session}
      max_width={:xl}
      flash={@flash}
    >
      <div class="space-y-6">
        <section>
          <div class="flex items-baseline justify-between mb-3">
            <h2 class="text-sm font-semibold uppercase tracking-wider text-zinc-500 dark:text-zinc-400">
              Quarantined agents
              <span class="text-zinc-400 font-normal">({length(@quarantined)})</span>
            </h2>
          </div>

          <p class="text-xs text-zinc-500 dark:text-zinc-400 mb-4">
            Agents here crashed too many times in a short window and the RestartController
            stopped respawning them. Releasing an agent clears the quarantine flag and
            allows the next start_agent call to succeed. Investigate the underlying
            crash cause before releasing — otherwise the agent will hit quarantine again.
          </p>

          <%= if @quarantined == [] do %>
            <div class="text-sm text-zinc-400 dark:text-zinc-500 italic">
              No agents are currently quarantined.
            </div>
          <% else %>
            <div class="rounded-lg border border-zinc-200 dark:border-zinc-700/80 overflow-hidden">
              <table class="w-full text-xs">
                <thead>
                  <tr class="bg-zinc-100 dark:bg-zinc-800 text-zinc-500 dark:text-zinc-400 text-left">
                    <th class="px-3 py-2 font-medium">Agent</th>
                    <th class="px-3 py-2 font-medium">Workspace</th>
                    <th class="px-3 py-2 font-medium">Quarantined at</th>
                    <th class="px-3 py-2 font-medium">Reason</th>
                    <th class="px-3 py-2 font-medium w-24"></th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={q <- @quarantined} class="border-t border-zinc-200 dark:border-zinc-700/50">
                    <td class="px-3 py-2 font-mono">
                      <div class="font-semibold">{q.name}</div>
                      <div class="text-zinc-400 text-[11px]">{q.id}</div>
                    </td>
                    <td class="px-3 py-2 font-mono text-zinc-500">{q.workspace_id || "—"}</td>
                    <td class="px-3 py-2 text-zinc-500">
                      <%= if q.crashed_at, do: Calendar.strftime(q.crashed_at, "%Y-%m-%d %H:%M:%S"), else: "—" %>
                    </td>
                    <td class="px-3 py-2 text-zinc-600 dark:text-zinc-400 max-w-[400px] truncate">
                      {q.reason || "—"}
                    </td>
                    <td class="px-3 py-2">
                      <button
                        phx-click="release"
                        phx-value-id={q.id}
                        data-confirm={"Release #{q.name} from quarantine? The agent will be allowed to start again."}
                        class="rounded-md bg-emerald-600 hover:bg-emerald-700 text-white px-2 py-1 font-medium transition-colors"
                      >
                        Release
                      </button>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>
      </div>
    </.page_shell>
    """
  end
end
