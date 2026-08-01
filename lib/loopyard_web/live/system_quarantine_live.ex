defmodule LoopyardWeb.SystemQuarantineLive do
  @moduledoc """
  Lists every quarantined ChatAgent across every workspace. Operators
  click "Release" to un-quarantine and respawn. Subscribes to the
  chat_agents topic so the list updates live as agents enter or
  leave quarantine.

  Part of the coordination-hardening plan Move #10. The quarantine
  mechanism itself lives in `Loopyard.ChatAgent.RestartController`;
  this LV is the operator-facing surface.
  """
  use LoopyardWeb, :live_view
  use LoopyardWeb.IExAware

  alias Loopyard.ChatAgent.RestartController
  alias Loopyard.Events

  @behaviour Loopyard.Events.ChatAgent.Subscriber

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Loopyard.Events.ChatAgent.subscribe()
    end

    {:ok,
     socket
     |> assign_iex()
     |> assign(:quarantined, RestartController.list_quarantined())}
  end

  defp assign_iex(socket) do
    if connected?(socket),
      do: subscribe_iex(socket),
      else: assign(socket, :iex_session, %{level: nil})
  end

  # --- PubSub dispatch ---

  @impl true
  def handle_info(%Events.ChatAgent.Quarantined{} = e, socket), do: on_quarantined(e, socket)
  def handle_info(%Events.ChatAgent.Released{} = e, socket), do: on_released(e, socket)

  # Other chat_agents topic events are ignored here — the
  # /system/quarantine page only cares about quarantine-specific
  # transitions. The callbacks still exist (one per event on the topic)
  # but return the socket unchanged, which is the explicit opt-out.
  def handle_info(%Events.ChatAgent.Started{} = e, socket), do: on_started(e, socket)
  def handle_info(%Events.ChatAgent.Stopped{} = e, socket), do: on_stopped(e, socket)
  def handle_info(%Events.ChatAgent.Booting{} = e, socket), do: on_booting(e, socket)
  def handle_info(%Events.ChatAgent.BootStatus{} = e, socket), do: on_boot_status(e, socket)
  def handle_info(%Events.ChatAgent.BootFailed{} = e, socket), do: on_boot_failed(e, socket)
  def handle_info(%Events.ChatAgent.Removed{} = e, socket), do: on_removed(e, socket)
  def handle_info(%Events.ChatAgent.Renamed{} = e, socket), do: on_renamed(e, socket)
  def handle_info(%Events.ChatAgent.Resumed{} = e, socket), do: on_resumed(e, socket)
  def handle_info(%Events.ChatAgent.StatusChanged{} = e, socket), do: on_status_changed(e, socket)

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Subscriber callbacks ---
  #
  # Only quarantine events cause a list refresh. The rest are implicit
  # no-ops so the @behaviour declaration has a matching implementation
  # for every callback — a new event added to the topic will surface as
  # a compile warning here until we decide whether it affects this page.

  @impl Events.ChatAgent.Subscriber
  def on_quarantined(_e, socket) do
    {:noreply, assign(socket, :quarantined, RestartController.list_quarantined())}
  end

  @impl Events.ChatAgent.Subscriber
  def on_released(_e, socket) do
    {:noreply, assign(socket, :quarantined, RestartController.list_quarantined())}
  end

  @impl Events.ChatAgent.Subscriber
  def on_started(_e, socket), do: {:noreply, socket}
  @impl Events.ChatAgent.Subscriber
  def on_stopped(_e, socket), do: {:noreply, socket}
  @impl Events.ChatAgent.Subscriber
  def on_booting(_e, socket), do: {:noreply, socket}
  @impl Events.ChatAgent.Subscriber
  def on_boot_status(_e, socket), do: {:noreply, socket}
  @impl Events.ChatAgent.Subscriber
  def on_boot_failed(_e, socket), do: {:noreply, socket}
  @impl Events.ChatAgent.Subscriber
  def on_removed(_e, socket), do: {:noreply, socket}
  @impl Events.ChatAgent.Subscriber
  def on_renamed(_e, socket), do: {:noreply, socket}
  @impl Events.ChatAgent.Subscriber
  def on_resumed(_e, socket), do: {:noreply, socket}
  @impl Events.ChatAgent.Subscriber
  def on_status_changed(_e, socket), do: {:noreply, socket}

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
      mode={:system}
      breadcrumbs={[{"Loopyard", "/"}, {"System", "/system"}, {"Quarantine", nil}]}
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
            <div class="text-sm text-zinc-500 dark:text-zinc-400 italic">
              No agents are currently quarantined.
            </div>
          <% else %>
            <div class="rounded-sm border border-zinc-200 dark:border-zinc-700/80 overflow-hidden">
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
                  <tr
                    :for={q <- @quarantined}
                    class="border-t border-zinc-200 dark:border-zinc-700/50"
                  >
                    <td class="px-3 py-2 font-mono">
                      <div class="font-semibold">{q.name}</div>
                      <div class="text-zinc-400 text-xs">{q.id}</div>
                    </td>
                    <td class="px-3 py-2 font-mono text-zinc-500">{q.workspace_id || "—"}</td>
                    <td class="px-3 py-2 text-zinc-500">
                      {if q.crashed_at,
                        do: Calendar.strftime(q.crashed_at, "%Y-%m-%d %H:%M:%S"),
                        else: "—"}
                    </td>
                    <td class="px-3 py-2 text-zinc-600 dark:text-zinc-400 max-w-[400px] truncate">
                      {q.reason || "—"}
                    </td>
                    <td class="px-3 py-2">
                      <button
                        phx-click="release"
                        phx-value-id={q.id}
                        data-confirm={"Release #{q.name} from quarantine? The agent will be allowed to start again."}
                        class="rounded-sm bg-emerald-600 hover:bg-emerald-700 text-white px-2 py-1 font-medium transition-colors"
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
