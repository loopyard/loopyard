defmodule LoopyardWeb.ConnectLive do
  use LoopyardWeb, :live_view
  use LoopyardWeb.IExAware

  @impl true
  def mount(params, _session, socket) do
    # Path comes from the catch-all route: /remote/*path
    path =
      case Map.get(params, "path") do
        nil -> "/"
        segments when is_list(segments) -> "/" <> Enum.join(segments, "/")
        p -> p
      end

    exposed = Loopyard.HostExposer.exposed?()

    socket =
      if connected?(socket),
        do: subscribe_iex(socket),
        else: assign(socket, :iex_session, %{level: nil})

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

    Task.Supervisor.start_child(Loopyard.TaskSupervisor, fn ->
      Loopyard.HostExposer.enable()
      send(socket.root_pid, :exposure_changed)
    end)

    {:noreply, socket}
  end

  def handle_event("unexpose", _params, socket) do
    socket = assign(socket, :toggling, true)

    Task.Supervisor.start_child(Loopyard.TaskSupervisor, fn ->
      Loopyard.HostExposer.disable()
      send(socket.root_pid, :exposure_changed)
    end)

    {:noreply, socket}
  end

  @impl true
  def handle_info(:exposure_changed, socket) do
    exposed = Loopyard.HostExposer.exposed?()

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
    ssh_cmd = "ssh -p #{Loopyard.SSHServer.port()} CONTAINER@#{lan_ip}"

    socket
    |> assign(:url, url)
    |> assign(:qr_svg, qr_svg)
    |> assign(:ssh_cmd, ssh_cmd)
    |> assign(:lan_ip, lan_ip)
  end

  defp maybe_assign_qr(socket, false, _path) do
    socket
    |> assign(:url, nil)
    |> assign(:qr_svg, nil)
    |> assign(:ssh_cmd, nil)
    |> assign(:lan_ip, nil)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_shell
      breadcrumbs={[{"Loopyard", "/"}, {"Remote", nil}]}
      iex_session={@iex_session}
      max_width={:lg}
      flash={@flash}
    >
      <:header_actions>
        <button
          :if={@exposed && !@toggling}
          phx-click="unexpose"
          data-confirm="This disconnects any remote sessions (including this one, if you're connected remotely). Continue?"
          class="focus-ring inline-flex items-center gap-1.5 rounded-lg px-3 py-1.5 text-xs font-medium text-red-600 dark:text-red-400 hover:bg-red-50 dark:hover:bg-red-500/10 transition-colors"
        >
          Stop exposing
        </button>
      </:header_actions>

      <div :if={@toggling} class="flex items-center gap-2 text-sm text-zinc-500 dark:text-zinc-400 py-16">
        <span class="w-2 h-2 rounded-full bg-violet-500 animate-pulse flex-none"></span>
        Restarting the endpoint…
      </div>

      <div :if={!@toggling && @exposed} class="space-y-6">
        <%!-- Status: exposed, and the address it's on. --%>
        <div class="flex flex-wrap items-center gap-x-2 gap-y-1 text-sm">
          <span class="w-2 h-2 rounded-full bg-emerald-500 flex-none"></span>
          <span class="font-medium text-emerald-600 dark:text-emerald-400">Exposed</span>
          <span class="text-zinc-500 dark:text-zinc-400">
            — reachable on your network at
            <code class="font-mono text-zinc-700 dark:text-zinc-300">{@lan_ip}</code>
          </span>
        </div>

        <%!-- QR hero (scan target) + connection details. Stacks on phone, sits
             side-by-side on desktop with the QR as a fixed-width anchor. --%>
        <div class="grid gap-6 md:grid-cols-[auto_minmax(0,1fr)] md:items-start">
          <div class="rounded-2xl border border-zinc-200 dark:border-zinc-800 bg-brand-paper dark:bg-brand-ink/40 p-4 w-max mx-auto md:mx-0">
            <div class="bg-white rounded-xl p-2.5 w-max">{raw(@qr_svg)}</div>
            <p class="text-xs text-zinc-500 dark:text-zinc-400 mt-3 max-w-[240px] text-center">
              Scan to open on your phone or another device.
            </p>
          </div>

          <div class="space-y-6 min-w-0">
            <section class="space-y-2">
              <h2 class="text-xs font-semibold uppercase tracking-wide text-zinc-500 dark:text-zinc-400">
                Open in a browser
              </h2>
              <.copy_line id="copy-url" value={@url} />
              <p :if={@path != "/"} class="text-xs text-zinc-500 dark:text-zinc-400 font-mono truncate">
                deep link: {@path}
              </p>
            </section>

            <%!-- SSH by container name (SSHServer authenticates by name, no
                 password) — swap CONTAINER for the one you want. --%>
            <section :if={@ssh_cmd} class="space-y-2">
              <h2 class="text-xs font-semibold uppercase tracking-wide text-zinc-500 dark:text-zinc-400">
                SSH into a container
              </h2>
              <.copy_line id="copy-ssh" value={@ssh_cmd} />
              <p class="text-xs text-zinc-500 dark:text-zinc-400 leading-relaxed">
                Replace
                <code class="bg-zinc-100 dark:bg-zinc-800 rounded px-1 py-0.5 font-mono">CONTAINER</code>
                with a running container's name (shown on any service's console page).
              </p>
            </section>
          </div>
        </div>
      </div>

      <%!-- Private: a single explanatory card + the one CTA. --%>
      <div
        :if={!@toggling && !@exposed}
        class="max-w-xl space-y-4 rounded-2xl border border-zinc-200 dark:border-zinc-800 bg-brand-paper dark:bg-brand-ink/40 p-6"
      >
        <div class="flex items-center gap-2 text-sm">
          <span class="w-2 h-2 rounded-full bg-zinc-400 flex-none"></span>
          <span class="font-medium">Private</span>
          <span class="text-zinc-500 dark:text-zinc-400">— only this machine can reach Loopyard.</span>
        </div>
        <p class="text-sm text-zinc-500 dark:text-zinc-400 leading-relaxed">
          Loopyard is bound to
          <code class="bg-zinc-100 dark:bg-zinc-800 rounded px-1.5 py-0.5 font-mono">127.0.0.1</code>.
          Exposing binds it to
          <code class="bg-zinc-100 dark:bg-zinc-800 rounded px-1.5 py-0.5 font-mono">0.0.0.0</code>
          so any device that can route to this host — same Wi-Fi, VPN, tunnel — can reach it, with a
          QR code and SSH details to connect.
        </p>
        <button
          phx-click="expose"
          class="focus-ring inline-flex items-center gap-2 rounded-lg bg-violet-600 hover:bg-violet-700 text-white px-5 py-2.5 text-sm font-medium transition-colors"
        >
          Expose endpoint
        </button>
      </div>
    </.page_shell>
    """
  end

  # A monospace value + a Copy button, matching our command-box rhythm. Uses the
  # CopySource hook (works over plain-HTTP LAN via the execCommand fallback).
  attr :id, :string, required: true
  attr :value, :string, required: true

  defp copy_line(assigns) do
    ~H"""
    <div class="flex items-stretch gap-2">
      <code class="flex-1 min-w-0 overflow-x-auto rounded-lg bg-zinc-100 dark:bg-zinc-800/80 ring-1 ring-inset ring-zinc-200 dark:ring-zinc-700/60 text-zinc-700 dark:text-zinc-200 text-sm font-mono px-3 py-2 select-all whitespace-nowrap">{@value}</code>
      <button
        id={@id}
        phx-hook="CopySource"
        data-source={@value}
        class="focus-ring flex-none rounded-lg bg-zinc-900 hover:bg-zinc-700 text-white dark:bg-zinc-100 dark:text-zinc-900 dark:hover:bg-white px-3.5 py-2 text-xs font-medium transition-colors"
      >
        <span class="copy-icon">Copy</span>
        <span class="check-icon hidden">Copied</span>
      </button>
    </div>
    """
  end

  @doc false
  def build_remote_url(path \\ "/") do
    host = detect_lan_ip()
    port = Application.get_env(:loopyard, LoopyardWeb.Endpoint)[:http][:port] || 4000
    %URI{scheme: "http", host: host, port: port, path: path} |> URI.to_string()
  end

  defp detect_lan_ip do
    case System.cmd("ipconfig", ["getifaddr", "en0"], stderr_to_stdout: true) do
      {output, 0} ->
        String.trim(output)

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
