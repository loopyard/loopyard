defmodule BoomLooperWeb.SystemPortsLive do
  @moduledoc """
  Audit page for every host port BoomLooper has assigned.

  Each row shows the workspace/service/container_port → host_port mapping,
  whether it's exposed to the LAN, and (for exposed ports) live byte
  counters + connection counts pulled from the running PortExposer.
  """
  use BoomLooperWeb, :live_view
  use BoomLooperWeb.IExAware

  alias BoomLooper.{PortExposer, PortRegistry}

  @refresh_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(@refresh_ms, :refresh)
    end

    socket =
      socket
      |> assign_iex()
      |> assign_rows()

    {:ok, socket}
  end

  defp assign_iex(socket) do
    if connected?(socket), do: subscribe_iex(socket), else: assign(socket, :iex_session, %{level: nil})
  end

  defp assign_rows(socket) do
    rows =
      :ets.tab2list(:port_registry)
      |> Enum.map(fn {_, entry} -> entry end)
      |> Enum.sort_by(& &1.host_port)
      |> Enum.map(&decorate_row/1)

    assign(socket, :rows, rows)
  end

  defp decorate_row(entry) do
    key = {entry.workspace_id, entry.service, entry.container_port}

    status =
      case PortExposer.status(key) do
        :not_running -> nil
        s -> s
      end

    Map.put(entry, :live, status)
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, assign_rows(socket)}
  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle", %{"ws" => ws, "svc" => svc, "cport" => cport, "expose" => expose}, socket) do
    cport = String.to_integer(cport)
    expose? = expose == "true"

    case PortRegistry.set_exposure(ws, svc, cport, expose?) do
      :ok ->
        {:noreply, assign_rows(socket)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Toggle failed: #{inspect(reason)}")}
    end
  end

  def handle_event("remove", %{"ws" => ws, "svc" => svc, "cport" => cport}, socket) do
    cport = String.to_integer(cport)
    # Releasing the workspace would nuke ALL its entries — too coarse.
    # We need a single-entry release path. For now, close exposure and
    # warn the operator that container restart will re-assign.
    PortRegistry.set_exposure(ws, svc, cport, false)

    {:noreply,
     put_flash(socket, :info,
       "Closed exposure. To reclaim the host port, destroy the workspace " <>
         "or stop using the service."
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_shell breadcrumbs={[{"Boom Looper", "/"}, {"System", "/system"}, {"Ports", nil}]} iex_session={@iex_session} max_width={:lg} flash={@flash}>
      <h2 class="text-sm font-semibold uppercase tracking-wider text-zinc-500 dark:text-zinc-400 mb-3">
        Ports <span class="text-zinc-400 font-normal">({length(@rows)})</span>
      </h2>

      <p class="text-xs text-zinc-500 dark:text-zinc-400 mb-4">
        Every row is a host port BoomLooper has assigned to a workspace service.
        By default each one is bound to <code>127.0.0.1</code> — only this machine
        can reach it. Click <strong>Expose</strong> to bind it to <code>0.0.0.0</code>
        so anything that can route to this host (LAN, tunnel, VPN, public IP) can reach it.
      </p>

      <div :if={@rows == []} class="text-sm text-zinc-400 dark:text-zinc-500">No ports assigned</div>

      <div :if={@rows != []} class="overflow-x-auto">
        <table class="w-full text-sm">
          <thead class="text-xs uppercase tracking-wider text-zinc-400 dark:text-zinc-500 border-b border-zinc-200 dark:border-zinc-700">
            <tr>
              <th class="text-left font-semibold py-2 px-2">Workspace</th>
              <th class="text-left font-semibold py-2 px-2">Service</th>
              <th class="text-right font-semibold py-2 px-2">Host → Container</th>
              <th class="text-left font-semibold py-2 px-2">Binding</th>
              <th class="text-right font-semibold py-2 px-2">Conns</th>
              <th class="text-right font-semibold py-2 px-2">In / Out</th>
              <th class="text-left font-semibold py-2 px-2">Peers</th>
              <th class="py-2 px-2"></th>
            </tr>
          </thead>
          <tbody class="divide-y divide-zinc-100 dark:divide-zinc-800">
            <.port_row :for={r <- @rows} r={r} />
          </tbody>
        </table>
      </div>
    </.page_shell>
    """
  end

  attr :r, :map, required: true

  defp port_row(assigns) do
    ~H"""
    <tr>
      <td class="py-2 px-2 font-mono text-xs text-zinc-500">{@r.workspace_id}</td>
      <td class="py-2 px-2">{@r.service}</td>
      <td class="py-2 px-2 text-right font-mono text-xs">
        <span class={if @r.exposed, do: "text-emerald-600 dark:text-emerald-400", else: "text-zinc-500"}>
          {@r.host_port}
        </span>
        <span class="text-zinc-400">→</span>
        <span>{@r.container_port}</span>
      </td>
      <td class="py-2 px-2">
        <span :if={@r.exposed} class="text-xs font-medium text-emerald-600 dark:text-emerald-400 bg-emerald-500/10 rounded-full px-2 py-0.5">
          Exposed (0.0.0.0)
        </span>
        <span :if={!@r.exposed} class="text-xs text-zinc-500">Loopback (127.0.0.1)</span>
        <span :if={@r.legacy} class="ml-1 text-[10px] uppercase tracking-wider text-amber-500">legacy</span>
      </td>
      <td class="py-2 px-2 text-right font-mono text-xs">
        {if @r.live, do: @r.live.connection_count, else: "—"}
      </td>
      <td class="py-2 px-2 text-right font-mono text-xs text-zinc-500">
        {bytes(@r.live, :bytes_in)} / {bytes(@r.live, :bytes_out)}
      </td>
      <td class="py-2 px-2 font-mono text-[10px] text-zinc-500 truncate max-w-[200px]">
        {if @r.live, do: Enum.join(@r.live.peers, ", "), else: ""}
      </td>
      <td class="py-2 px-2 text-right">
        <button
          phx-click="toggle"
          phx-value-ws={@r.workspace_id}
          phx-value-svc={@r.service}
          phx-value-cport={@r.container_port}
          phx-value-expose={to_string(!@r.exposed)}
          class={[
            "text-xs font-medium rounded px-2 py-1 transition-colors",
            if(@r.exposed,
              do: "text-zinc-600 dark:text-zinc-400 hover:bg-zinc-100 dark:hover:bg-zinc-700",
              else: "text-emerald-600 dark:text-emerald-400 hover:bg-emerald-50 dark:hover:bg-emerald-500/10")
          ]}
        >
          {if @r.exposed, do: "Unexpose", else: "Expose"}
        </button>
      </td>
    </tr>
    """
  end

  defp bytes(nil, _), do: "—"
  defp bytes(live, key), do: humanize_bytes(Map.get(live, key, 0))

  defp humanize_bytes(n) when n < 1024, do: "#{n}B"
  defp humanize_bytes(n) when n < 1024 * 1024, do: "#{Float.round(n / 1024, 1)}K"
  defp humanize_bytes(n) when n < 1024 * 1024 * 1024, do: "#{Float.round(n / 1024 / 1024, 1)}M"
  defp humanize_bytes(n), do: "#{Float.round(n / 1024 / 1024 / 1024, 1)}G"
end
