defmodule BoomLooperWeb.Live.WorkspaceLive.Components.Services do
  @moduledoc "Service-related views: service_log_view, console_view, all_services_view."
  use Phoenix.Component

  import BoomLooperWeb.Components.Common, only: [detail_panel: 1, control_btn: 1, dot: 1]
  import BoomLooperWeb.Components.LogViewer
  import BoomLooperWeb.Components.Sidebar, only: [service_dot: 1, service_detail: 1, first_host_port: 1]

  def service_log_view(assigns) do
    svc = Enum.find(assigns.service_statuses, &(&1.name == assigns.service_name))
    first_port = if svc, do: first_host_port(svc.ports), else: nil
    running? = svc && svc.status == :running
    assigns = assign(assigns, svc: svc, first_port: first_port, running?: running?)

    ~H"""
    <.detail_panel>
      <:header>
        <.dot :if={@svc} color={service_dot(@svc)} />
        <span class="text-sm font-semibold text-zinc-900 dark:text-zinc-100">{@service_name}</span>
        <span :if={@svc} class="text-xs text-zinc-400 dark:text-zinc-500 font-mono">{service_detail(@svc)}</span>
        <a :if={@first_port} href={"http://#{@host}:#{@first_port}"} target="_blank"
          class="text-xs font-mono text-violet-500 hover:text-violet-400 transition-colors">
          {@host}:{@first_port}
        </a>
        <div class="ml-auto flex items-center gap-2">
          <%!--
            Running → Restart + Stop. Stopped/crashed → Start (compose
            up -d brings it back; `restart` on a stopped container is
            a no-op). When we can't identify the service yet, show
            Start so the button always points at a useful action.
          --%>
          <.control_btn :if={@running?}
            phx-click="restart_service" phx-value-service_name={@service_name}>
            Restart
          </.control_btn>
          <.control_btn :if={!@running?} variant={:primary}
            phx-click="start_service" phx-value-service_name={@service_name}>
            Start
          </.control_btn>
          <.control_btn :if={@running?}
            phx-click="stop_service" phx-value-service_name={@service_name}>
            Stop
          </.control_btn>
          <.link :if={@running?} navigate={"#{@base_path}/services/#{@service_name}/console"}
            class="inline-block px-2.5 py-1 rounded-md text-xs font-medium bg-zinc-100 dark:bg-zinc-800 hover:bg-zinc-200 dark:hover:bg-zinc-700 text-zinc-600 dark:text-zinc-300 transition-colors">
            Console
          </.link>
          <a :if={@first_port} href={"http://#{@host}:#{@first_port}"} target="_blank" rel="noopener"
            class="px-2.5 py-1 rounded-md text-xs font-medium bg-zinc-100 dark:bg-zinc-800 hover:bg-zinc-200 dark:hover:bg-zinc-700 text-zinc-600 dark:text-zinc-300 transition-colors">
            Open
          </a>
        </div>
      </:header>
      <%!-- Service is up → show logs. Service is stopped/missing →
           show a clear empty state pointing the user at Start,
           rather than the confusing "(could not fetch logs)" that
           used to render a blank log panel. --%>
      <.log_panel :if={@running?} id="service-logs" content={@logs} />
      <.service_stopped_panel :if={!@running?} service_name={@service_name} svc={@svc} workspace_state={@workspace_state} />
    </.detail_panel>
    """
  end

  # Empty-state for a service that isn't running. Big label + Start
  # button so the action the user needs is front-and-center.
  defp service_stopped_panel(assigns) do
    ~H"""
    <div class="flex-1 flex items-center justify-center">
      <div class="text-center max-w-sm px-4">
        <div class="w-14 h-14 rounded-2xl bg-zinc-100 dark:bg-zinc-800 flex items-center justify-center mx-auto mb-4">
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor" class="w-6 h-6 text-zinc-300 dark:text-zinc-600">
            <path fill-rule="evenodd" d="M4.5 7.5a3 3 0 0 1 3-3h9a3 3 0 0 1 3 3v9a3 3 0 0 1-3 3h-9a3 3 0 0 1-3-3v-9Z" clip-rule="evenodd" />
          </svg>
        </div>
        <h3 class="text-sm font-semibold text-zinc-900 dark:text-zinc-100 mb-1">
          {@service_name} is stopped
        </h3>
        <p :if={@workspace_state in [:stopped, :starting]} class="text-xs text-zinc-500 dark:text-zinc-400 mb-4">
          The workspace cluster is {@workspace_state}. Start it from the sidebar to bring this service up.
        </p>
        <p :if={@workspace_state not in [:stopped, :starting]} class="text-xs text-zinc-500 dark:text-zinc-400 mb-4">
          Start it to see live logs.
        </p>
        <button :if={@workspace_state not in [:stopped, :starting]}
          phx-click="start_service" phx-value-service_name={@service_name}
          class="focus-ring inline-flex items-center gap-2 rounded-lg bg-violet-600 hover:bg-violet-700 text-white px-5 py-2.5 text-sm font-medium transition-colors">
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class="w-4 h-4" aria-hidden="true">
            <path d="M6.3 2.84A1.5 1.5 0 0 0 4 4.11v11.78a1.5 1.5 0 0 0 2.3 1.27l9.344-5.891a1.5 1.5 0 0 0 0-2.538L6.3 2.841Z" />
          </svg>
          Start {@service_name}
        </button>
      </div>
    </div>
    """
  end

  def console_view(assigns) do
    ssh_cmd = if assigns.container do
      "ssh -p #{BoomLooper.SSHServer.port()} #{assigns.container}@localhost"
    end

    assigns = assign(assigns, :ssh_cmd, ssh_cmd)

    ~H"""
    <.detail_panel>
      <:header>
        <span class="text-sm font-semibold text-zinc-900 dark:text-zinc-100">{@service_name}</span>
        <span class="text-xs text-zinc-400 dark:text-zinc-500">console</span>
        <div :if={@ssh_cmd} class="ml-auto">
          <button id="copy-ssh" phx-hook="CopySource" data-source={@ssh_cmd}
            class="flex items-center gap-1.5 text-xs text-zinc-400 hover:text-zinc-300 transition-colors font-mono">
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-3.5 h-3.5 copy-icon">
              <path d="M5.5 3.5A1.5 1.5 0 0 1 7 2h2.879a1.5 1.5 0 0 1 1.06.44l2.122 2.12a1.5 1.5 0 0 1 .439 1.061V9.5A1.5 1.5 0 0 1 12 11V8.621a3 3 0 0 0-.879-2.121L9 4.379A3 3 0 0 0 6.879 3.5H5.5Z" />
              <path d="M4 5a1.5 1.5 0 0 0-1.5 1.5v6A1.5 1.5 0 0 0 4 14h5a1.5 1.5 0 0 0 1.5-1.5V8.621a1.5 1.5 0 0 0-.44-1.06L7.94 5.439A1.5 1.5 0 0 0 6.878 5H4Z" />
            </svg>
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-3.5 h-3.5 check-icon hidden text-green-400">
              <path fill-rule="evenodd" d="M12.416 3.376a.75.75 0 0 1 .208 1.04l-5 7.5a.75.75 0 0 1-1.154.114l-3-3a.75.75 0 0 1 1.06-1.06l2.353 2.353 4.493-6.74a.75.75 0 0 1 1.04-.207Z" clip-rule="evenodd" />
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
      ></div>
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
