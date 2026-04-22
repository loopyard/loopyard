defmodule BoomLooperWeb.ConnectLive do
  use BoomLooperWeb, :live_view
  use BoomLooperWeb.IExAware

  @impl true
  def mount(params, _session, socket) do
    # Path comes from the catch-all route: /remote/*path
    path = case Map.get(params, "path") do
      nil -> "/"
      segments when is_list(segments) -> "/" <> Enum.join(segments, "/")
      p -> p
    end
    exposed = BoomLooper.HostExposer.exposed?()

    socket = if connected?(socket), do: subscribe_iex(socket), else: assign(socket, :iex_session, %{level: nil})

    {:ok,
     socket
     |> assign(:path, path)
     |> assign(:exposed, exposed)
     |> assign(:toggling, false)
     |> maybe_assign_qr(exposed, path)}
  end

  @impl true
  def handle_event("expose", _params, socket) do
    socket = assign(socket, :toggling, true)

    Task.Supervisor.start_child(BoomLooper.TaskSupervisor, fn ->
      BoomLooper.HostExposer.enable()
      send(socket.root_pid, :exposure_changed)
    end)

    {:noreply, socket}
  end

  def handle_event("unexpose", _params, socket) do
    socket = assign(socket, :toggling, true)

    Task.Supervisor.start_child(BoomLooper.TaskSupervisor, fn ->
      BoomLooper.HostExposer.disable()
      send(socket.root_pid, :exposure_changed)
    end)

    {:noreply, socket}
  end

  @impl true
  def handle_info(:exposure_changed, socket) do
    exposed = BoomLooper.HostExposer.exposed?()

    {:noreply,
     socket
     |> assign(:exposed, exposed)
     |> assign(:toggling, false)
     |> maybe_assign_qr(exposed, socket.assigns.path)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  defp maybe_assign_qr(socket, true, path) do
    url = build_remote_url(path)
    qr_svg = url |> EQRCode.encode() |> EQRCode.svg(width: 240)
    lan_ip = detect_lan_ip()
    ssh_cmd = "ssh -p #{BoomLooper.SSHServer.port()} CONTAINER@#{lan_ip}"

    socket
    |> assign(:url, url)
    |> assign(:qr_svg, qr_svg)
    |> assign(:ssh_cmd, ssh_cmd)
  end

  defp maybe_assign_qr(socket, false, _path) do
    socket
    |> assign(:url, nil)
    |> assign(:qr_svg, nil)
    |> assign(:ssh_cmd, nil)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-screen flex flex-col bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100">
      <.header breadcrumbs={[{"Boom Looper", "/"}, {"Remote", nil}]} iex_session={@iex_session} host_exposed={@exposed} />

      <div class="flex-1 flex items-center justify-center">
        <div class="text-center px-4 max-w-md">
          <%= if @toggling do %>
            <div class="text-sm text-zinc-500 animate-pulse py-8">Restarting endpoint...</div>
          <% else %>
            <%= if @exposed do %>
              <div class="bg-white p-5 rounded-2xl shadow-sm inline-block mb-6">
                {raw(@qr_svg)}
              </div>
              <p class="text-sm text-zinc-500 dark:text-zinc-400 mb-2">Scan to open on your phone or another device</p>
              <div class="flex items-center justify-center gap-2 mb-6">
                <code class="text-sm font-mono text-zinc-700 dark:text-zinc-300 bg-zinc-100 dark:bg-zinc-800 rounded-lg px-3 py-2 select-all">{@url}</code>
                <button id="copy-url" phx-hook="CopySource" data-source={@url}
                  class="text-xs text-violet-600 dark:text-violet-400 hover:text-violet-500 font-medium">Copy</button>
              </div>
              <p :if={@path != "/"} class="text-xs text-zinc-400 dark:text-zinc-500 mb-4 font-mono truncate">{@path}</p>
              <button phx-click="unexpose" data-confirm="This will disconnect any remote sessions (including this one if you're connected remotely). Continue?" class="text-xs font-medium text-red-600 dark:text-red-400 hover:bg-red-50 dark:hover:bg-red-500/10 rounded-lg px-4 py-2 transition-colors">
                Stop exposing
              </button>
            <% else %>
              <div class="space-y-4">
                <h2 class="text-lg font-semibold">Remote access</h2>
                <p class="text-sm text-zinc-500 dark:text-zinc-400 leading-relaxed">
                  BoomLooper is currently bound to <code class="bg-zinc-100 dark:bg-zinc-800 rounded px-1.5 py-0.5">127.0.0.1</code> — only this machine can reach it.
                  Exposing binds to <code class="bg-zinc-100 dark:bg-zinc-800 rounded px-1.5 py-0.5">0.0.0.0</code> so any device that can route to this host (same Wi-Fi, VPN, tunnel) can access it.
                </p>
                <button phx-click="expose" class="inline-flex items-center gap-2 rounded-lg bg-violet-600 hover:bg-violet-700 text-white px-5 py-2.5 text-sm font-medium transition-colors">
                  Expose endpoint
                </button>
              </div>
            <% end %>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  @doc false
  def build_remote_url(path \\ "/") do
    host = detect_lan_ip()
    port = Application.get_env(:boom_looper, BoomLooperWeb.Endpoint)[:http][:port] || 4000
    %URI{scheme: "http", host: host, port: port, path: path} |> URI.to_string()
  end

  defp detect_lan_ip do
    case System.cmd("ipconfig", ["getifaddr", "en0"], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      _ ->
        case System.cmd("hostname", ["-I"], stderr_to_stdout: true) do
          {output, 0} -> output |> String.trim() |> String.split() |> hd()
          _ -> "localhost"
        end
    end
  rescue
    _ -> "localhost"
  end
end
