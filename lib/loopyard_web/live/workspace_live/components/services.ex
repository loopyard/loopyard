defmodule LoopyardWeb.Live.WorkspaceLive.Components.Services do
  @moduledoc "Service-related views: service_log_view, console_view, all_services_view."
  use Phoenix.Component

  import LoopyardWeb.Components.Common, only: [detail_panel: 1, control_btn: 1, dot: 1]
  import LoopyardWeb.Components.LogViewer

  import LoopyardWeb.Components.Sidebar,
    only: [service_dot: 1, service_detail: 1, first_host_port: 1]

  def service_log_view(assigns) do
    svc = Enum.find(assigns.service_statuses, &(&1.name == assigns.service_name))
    first_port = if svc, do: Map.get(svc, :host_port) || first_host_port(svc.ports), else: nil
    running? = svc && svc.status == :running
    exposed? = svc && Map.get(svc, :exposed, false)
    container_port = svc && Map.get(svc, :container_port)

    assigns =
      assign(assigns,
        svc: svc,
        first_port: first_port,
        running?: running?,
        exposed?: exposed?,
        container_port: container_port
      )

    ~H"""
    <.detail_panel>
      <:header>
        <.dot :if={@svc} color={service_dot(@svc)} />
        <span class="text-sm font-semibold text-zinc-900 dark:text-zinc-100">{@service_name}</span>
        <span :if={@svc} class="text-xs text-zinc-400 dark:text-zinc-500 font-mono">
          {service_detail(@svc)}
        </span>
        <a
          :if={@first_port}
          href={"http://#{@host}:#{@first_port}"}
          target="_blank"
          class="text-xs font-mono text-violet-500 hover:text-violet-400 transition-colors"
        >
          {@host}:{@first_port}
        </a>
        <div class="ml-auto flex items-center gap-2">
          <%!--
            Running → Restart + Stop. Stopped/crashed → Start (compose
            up -d brings it back; `restart` on a stopped container is
            a no-op). When we can't identify the service yet, show
            Start so the button always points at a useful action.
          --%>
          <.control_btn
            :if={@running?}
            phx-click="restart_service"
            phx-value-service_name={@service_name}
          >
            Restart
          </.control_btn>
          <.control_btn
            :if={!@running?}
            variant={:primary}
            phx-click="start_service"
            phx-value-service_name={@service_name}
          >
            Start
          </.control_btn>
          <.control_btn
            :if={@running?}
            phx-click="stop_service"
            phx-value-service_name={@service_name}
          >
            Stop
          </.control_btn>
          <.control_btn :if={@running?} patch={"#{@base_path}/services/#{@service_name}/console"}>
            Console
          </.control_btn>
          <.control_btn
            :if={@first_port}
            href={"http://#{@host}:#{@first_port}"}
            target="_blank"
            rel="noopener"
          >
            Open
          </.control_btn>
          <.control_btn
            :if={@exposed? && @container_port}
            phx-click="toggle_port_exposure"
            phx-value-service={@service_name}
            phx-value-container_port={@container_port}
            phx-value-expose="false"
          >
            Close Port
          </.control_btn>
          <.control_btn
            :if={!@exposed? && @container_port && @running?}
            phx-click="toggle_port_exposure"
            phx-value-service={@service_name}
            phx-value-container_port={@container_port}
            phx-value-expose="true"
          >
            Open Port
          </.control_btn>
        </div>
      </:header>
      <%!-- Buffered frames (from LogBuffer) whenever there are ANY — including
           after a crash, so the output that killed it is still on screen. Only
           when the buffer is truly empty do we fall back to the starting /
           stopped empty states. --%>
      <.service_frames_panel :if={@frames != []} frames={@frames} />
      <.service_waiting_panel :if={@frames == [] && @running?} />
      <.service_starting_panel
        :if={@frames == [] && !@running? && @svc && @svc.status == :starting}
        service_name={@service_name}
      />
      <.service_stopped_panel
        :if={@frames == [] && !@running? && (!@svc || @svc.status != :starting)}
        service_name={@service_name}
        svc={@svc}
        workspace_state={@workspace_state}
      />
    </.detail_panel>
    """
  end

  # Streamed service logs, grouped by run so crash/restart boundaries are
  # visible. The last group is the current run; earlier ones ended (crashed or
  # stopped) — their output stays put because the buffer outlives the container.
  attr :frames, :list, required: true

  defp service_frames_panel(assigns) do
    assigns = assign(assigns, :last_i, length(assigns.frames) - 1)

    ~H"""
    <div class="flex-1 flex flex-col min-h-0">
      <%!-- Jump strip: tap a run to scroll to its boundary. Only when there's
           more than one run to jump between. --%>
      <div
        :if={length(@frames) > 1}
        class="flex-none flex items-center gap-1.5 px-3 py-1.5 border-b border-zinc-200 dark:border-zinc-800 bg-zinc-50 dark:bg-zinc-900/60 overflow-x-auto"
      >
        <span class="text-xs font-medium uppercase tracking-wide text-zinc-400 dark:text-zinc-500 flex-none mr-0.5">
          Runs
        </span>
        <a
          :for={{g, gi} <- Enum.with_index(@frames)}
          href={"#run-#{g.run}"}
          class={run_chip(gi == @last_i)}
        >
          {g.run}
        </a>
      </div>

      <div
        id="service-logs"
        phx-hook="LogTail"
        class="flex-1 min-h-0 overflow-y-auto bg-zinc-100 dark:bg-zinc-950 font-mono text-xs leading-relaxed"
      >
        <div :for={{group, gi} <- Enum.with_index(@frames)}>
          <%!-- Visual run divider — a sticky band so you always see which run
                you're scrolling through, and an anchor target for the jump strip. --%>
          <div
            id={"run-#{group.run}"}
            class="sticky top-0 z-10 flex items-center gap-2 px-3 h-8 border-y border-zinc-300 dark:border-zinc-700/70 bg-zinc-200/95 dark:bg-zinc-800/95 backdrop-blur text-xs font-semibold uppercase tracking-wide text-zinc-600 dark:text-zinc-300 scroll-mt-0"
          >
            <span class={[
              "w-2 h-2 rounded-full flex-none",
              if(gi == @last_i, do: "bg-emerald-500", else: "bg-zinc-400 dark:bg-zinc-600")
            ]}></span>
            Run {group.run}
            <span
              :if={gi < @last_i}
              class="font-normal normal-case text-zinc-400 dark:text-zinc-500"
            >
              · ended
            </span>
          </div>
          <div
            :for={f <- group.frames}
            class="flex gap-2 px-3 whitespace-pre-wrap break-words text-zinc-700 dark:text-zinc-300"
          >
            <span
              :if={f.ts}
              class="flex-none text-zinc-400 dark:text-zinc-600 tabular-nums select-none"
            >
              {short_ts(f.ts)}
            </span>
            <span>{f.text}</span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp run_chip(current?) do
    [
      "inline-flex items-center justify-center min-w-[1.9rem] h-7 px-2 rounded-md text-xs font-semibold flex-none transition-colors",
      if(current?,
        do: "bg-emerald-100 dark:bg-emerald-500/15 text-emerald-700 dark:text-emerald-400",
        else:
          "bg-zinc-200 dark:bg-zinc-800 text-zinc-600 dark:text-zinc-300 hover:bg-zinc-300 dark:hover:bg-zinc-700"
      )
    ]
  end

  defp service_waiting_panel(assigns) do
    ~H"""
    <div class="flex-1 flex items-center justify-center">
      <p class="text-sm text-zinc-400 dark:text-zinc-500">Waiting for output…</p>
    </div>
    """
  end

  # "2026-07-14T06:38:07.123456789Z" → "06:38:07"
  defp short_ts(ts) when is_binary(ts) do
    case String.split(ts, "T") do
      [_, time] -> time |> String.split(".") |> hd() |> String.slice(0, 8)
      _ -> ts
    end
  end

  defp short_ts(_), do: ""

  defp service_starting_panel(assigns) do
    ~H"""
    <div class="flex-1 flex items-center justify-center">
      <div class="text-center max-w-sm px-4">
        <div class="w-14 h-14 rounded-2xl bg-blue-50 dark:bg-blue-900/20 flex items-center justify-center mx-auto mb-4">
          <svg
            xmlns="http://www.w3.org/2000/svg"
            viewBox="0 0 24 24"
            fill="currentColor"
            class="w-6 h-6 text-blue-400 animate-pulse"
          >
            <path d="M6.3 2.84A1.5 1.5 0 0 0 4 4.11v11.78a1.5 1.5 0 0 0 2.3 1.27l9.344-5.891a1.5 1.5 0 0 0 0-2.538L6.3 2.841Z" />
          </svg>
        </div>
        <h3 class="text-sm font-semibold text-zinc-900 dark:text-zinc-100 mb-1">
          Starting {@service_name}...
        </h3>
      </div>
    </div>
    """
  end

  # Empty-state for a service that isn't running. Big label + Start
  # button so the action the user needs is front-and-center.
  defp service_stopped_panel(assigns) do
    ~H"""
    <div class="flex-1 flex items-center justify-center">
      <div class="text-center max-w-sm px-4">
        <div class="w-14 h-14 rounded-2xl bg-zinc-100 dark:bg-zinc-800 flex items-center justify-center mx-auto mb-4">
          <svg
            xmlns="http://www.w3.org/2000/svg"
            viewBox="0 0 24 24"
            fill="currentColor"
            class="w-6 h-6 text-zinc-300 dark:text-zinc-600"
          >
            <path
              fill-rule="evenodd"
              d="M4.5 7.5a3 3 0 0 1 3-3h9a3 3 0 0 1 3 3v9a3 3 0 0 1-3 3h-9a3 3 0 0 1-3-3v-9Z"
              clip-rule="evenodd"
            />
          </svg>
        </div>
        <h3 class="text-sm font-semibold text-zinc-900 dark:text-zinc-100 mb-1">
          {@service_name} is stopped
        </h3>
        <p
          :if={@workspace_state in [:stopped, :starting]}
          class="text-xs text-zinc-500 dark:text-zinc-400 mb-4"
        >
          The workspace is {@workspace_state}. Start it from the sidebar to bring services up.
        </p>
        <p
          :if={@workspace_state not in [:stopped, :starting]}
          class="text-xs text-zinc-500 dark:text-zinc-400 mb-4"
        >
          Start it to see live logs.
        </p>
        <button
          :if={@workspace_state not in [:stopped, :starting]}
          phx-click="start_service"
          phx-value-service_name={@service_name}
          class="focus-ring inline-flex items-center gap-2 rounded-lg bg-violet-600 hover:bg-violet-700 text-white px-5 py-2.5 text-sm font-medium transition-colors"
        >
          <svg
            xmlns="http://www.w3.org/2000/svg"
            viewBox="0 0 20 20"
            fill="currentColor"
            class="w-4 h-4"
            aria-hidden="true"
          >
            <path d="M6.3 2.84A1.5 1.5 0 0 0 4 4.11v11.78a1.5 1.5 0 0 0 2.3 1.27l9.344-5.891a1.5 1.5 0 0 0 0-2.538L6.3 2.841Z" />
          </svg>
          Start {@service_name}
        </button>
      </div>
    </div>
    """
  end

  def console_view(assigns) do
    ssh_cmd =
      if assigns.container do
        "ssh -p #{Loopyard.SSHServer.port()} #{assigns.container}@localhost"
      end

    assigns = assign(assigns, :ssh_cmd, ssh_cmd)

    ~H"""
    <.detail_panel>
      <:header>
        <span class="text-sm font-semibold text-zinc-900 dark:text-zinc-100">{@service_name}</span>
        <span class="text-xs text-zinc-400 dark:text-zinc-500">console</span>
        <div :if={@ssh_cmd} class="ml-auto">
          <button
            id="copy-ssh"
            phx-hook="CopySource"
            data-source={@ssh_cmd}
            class="flex items-center gap-1.5 text-xs text-zinc-400 hover:text-zinc-300 transition-colors font-mono"
          >
            <svg
              xmlns="http://www.w3.org/2000/svg"
              viewBox="0 0 16 16"
              fill="currentColor"
              class="w-3.5 h-3.5 copy-icon"
            >
              <path d="M5.5 3.5A1.5 1.5 0 0 1 7 2h2.879a1.5 1.5 0 0 1 1.06.44l2.122 2.12a1.5 1.5 0 0 1 .439 1.061V9.5A1.5 1.5 0 0 1 12 11V8.621a3 3 0 0 0-.879-2.121L9 4.379A3 3 0 0 0 6.879 3.5H5.5Z" />
              <path d="M4 5a1.5 1.5 0 0 0-1.5 1.5v6A1.5 1.5 0 0 0 4 14h5a1.5 1.5 0 0 0 1.5-1.5V8.621a1.5 1.5 0 0 0-.44-1.06L7.94 5.439A1.5 1.5 0 0 0 6.878 5H4Z" />
            </svg>
            <svg
              xmlns="http://www.w3.org/2000/svg"
              viewBox="0 0 16 16"
              fill="currentColor"
              class="w-3.5 h-3.5 check-icon hidden text-green-400"
            >
              <path
                fill-rule="evenodd"
                d="M12.416 3.376a.75.75 0 0 1 .208 1.04l-5 7.5a.75.75 0 0 1-1.154.114l-3-3a.75.75 0 0 1 1.06-1.06l2.353 2.353 4.493-6.74a.75.75 0 0 1 1.04-.207Z"
                clip-rule="evenodd"
              />
            </svg>
            SSH
          </button>
        </div>
      </:header>
      <div
        :if={@container}
        id={"terminal-#{@container}"}
        phx-hook="Terminal"
        data-container={@container}
        phx-update="ignore"
        class="flex-1 bg-[#18181b] p-3"
      >
      </div>
      <div :if={!@container} class="flex-1 flex items-center justify-center">
        <p class="text-sm text-zinc-400">Service not running</p>
      </div>
    </.detail_panel>
    """
  end

  def all_services_view(assigns) do
    ~H"""
    <.detail_panel>
      <:header>
        <span class="text-sm font-semibold text-zinc-900 dark:text-zinc-100">All Services</span>
      </:header>
      <.log_multi_service logs={@all_service_logs} />
    </.detail_panel>
    """
  end
end
