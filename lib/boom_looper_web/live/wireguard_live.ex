defmodule BoomLooperWeb.WireGuardLive do
  use BoomLooperWeb, :live_view

  alias BoomLooper.WireGuard

  @ios_app_url "https://apps.apple.com/app/wireguard/id1441195209"

  @impl true
  def mount(_params, _session, socket) do
    available = WireGuard.available?()
    clients = if available, do: WireGuard.list_clients(), else: []
    interface_up = if available, do: WireGuard.interface_up?(), else: false

    # Pre-generate QR codes
    app_qr_svg = @ios_app_url |> EQRCode.encode() |> EQRCode.svg(width: 160)

    host_ip = WireGuard.detect_host_ip()
    port = Application.get_env(:boom_looper, BoomLooperWeb.Endpoint)[:http][:port] || 4000
    access_url = "http://#{host_ip}:#{port}"
    access_qr_svg = access_url |> EQRCode.encode() |> EQRCode.svg(width: 200)

    {:ok,
     socket
     |> assign(:available, available)
     |> assign(:clients, clients)
     |> assign(:interface_up, interface_up)
     |> assign(:new_client, nil)
     |> assign(:app_qr_svg, app_qr_svg)
     |> assign(:setup_step, nil)
     |> assign(:setup_platform, nil)
     |> assign(:host_ip, host_ip)
     |> assign(:access_url, access_url)
     |> assign(:access_qr_svg, access_qr_svg)}
  end

  @impl true
  def handle_event("add_client", %{"name" => name}, socket) do
    name = String.trim(name)

    if name != "" do
      case WireGuard.add_client(name) do
        {:ok, client} ->
          config = WireGuard.client_config(client)
          qr_svg = WireGuard.client_qr_svg(client)

          unless WireGuard.interface_up?() do
            WireGuard.ensure_server_keys()
            WireGuard.up()
          end

          {:noreply,
           socket
           |> assign(:clients, WireGuard.list_clients())
           |> assign(:new_client, %{client: client, config: config, qr_svg: qr_svg})
           |> assign(:interface_up, WireGuard.interface_up?())}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed: #{reason}")}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("show_client", %{"name" => name}, socket) do
    client = Enum.find(socket.assigns.clients, &(&1["name"] == name))

    if client do
      config = WireGuard.client_config(client)
      qr_svg = WireGuard.client_qr_svg(client)
      {:noreply, assign(socket, :new_client, %{client: client, config: config, qr_svg: qr_svg})}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("remove_client", %{"name" => name}, socket) do
    WireGuard.remove_client(name)

    new_client = if socket.assigns.new_client && socket.assigns.new_client.client["name"] == name do
      nil
    else
      socket.assigns.new_client
    end

    {:noreply,
     socket
     |> assign(:clients, WireGuard.list_clients())
     |> assign(:new_client, new_client)}
  end

  @impl true
  def handle_event("toggle_interface", _params, socket) do
    if WireGuard.interface_up?() do
      WireGuard.down()
    else
      case WireGuard.ensure_server_keys() do
        {:ok, _} -> WireGuard.up()
        {:error, _} -> :ok
      end
    end

    {:noreply, assign(socket, :interface_up, WireGuard.interface_up?())}
  end

  @impl true
  def handle_event("pick_platform", %{"platform" => platform}, socket) do
    {:noreply, socket |> assign(:setup_platform, platform) |> assign(:setup_step, 1)}
  end

  @impl true
  def handle_event("next_step", _params, socket) do
    {:noreply, assign(socket, :setup_step, (socket.assigns.setup_step || 1) + 1)}
  end

  @impl true
  def handle_event("prev_step", _params, socket) do
    step = (socket.assigns.setup_step || 1) - 1
    if step < 1 do
      {:noreply, assign(socket, setup_step: nil, setup_platform: nil)}
    else
      {:noreply, assign(socket, :setup_step, step)}
    end
  end

  @impl true
  def handle_event("dismiss", _params, socket) do
    {:noreply, assign(socket, new_client: nil, setup_step: nil, setup_platform: nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-screen flex flex-col bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100">
      <header class="flex-none h-14 border-b border-zinc-200 dark:border-zinc-700/80 flex items-center px-4 md:px-5 gap-3">
        <.link navigate="/" class="text-lg font-semibold tracking-tight hover:text-violet-600 dark:hover:text-violet-400 transition-colors">Boom Looper</.link>
        <span class="text-zinc-300 dark:text-zinc-600">/</span>
        <span class="text-sm font-medium">Remote Access</span>
      </header>

      <div class="flex-1 overflow-y-auto">
        <div class="max-w-2xl mx-auto px-4 py-8">
          <p :if={@flash["error"]} class="mb-4 rounded-lg bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 px-4 py-3 text-sm text-red-700 dark:text-red-300">
            {@flash["error"]}
          </p>

          <div :if={!@available} class="text-center py-12">
            <p class="text-sm text-zinc-500 dark:text-zinc-400 mb-4">WireGuard tools are required for remote access.</p>
            <div class="rounded-xl border border-zinc-200 dark:border-zinc-700 p-6 inline-block text-left">
              <p class="text-xs font-semibold text-zinc-500 dark:text-zinc-400 uppercase tracking-wider mb-2">macOS</p>
              <code class="text-sm font-mono text-zinc-700 dark:text-zinc-300 bg-zinc-100 dark:bg-zinc-800 px-3 py-1.5 rounded-lg block">brew install wireguard-tools</code>
              <p class="text-xs font-semibold text-zinc-500 dark:text-zinc-400 uppercase tracking-wider mt-4 mb-2">Linux</p>
              <code class="text-sm font-mono text-zinc-700 dark:text-zinc-300 bg-zinc-100 dark:bg-zinc-800 px-3 py-1.5 rounded-lg block">sudo apt install wireguard-tools</code>
            </div>
          </div>

          <div :if={@available}>
            <div class="mb-6">
              <h2 class="text-xl font-semibold">Remote Access</h2>
              <p class="text-sm text-zinc-500 dark:text-zinc-400 mt-0.5">
                Connect your devices to access BoomLooper, SSH, and all service ports.
              </p>
            </div>

            <%!-- Direct access card with QR --%>
            <div class="mb-6 rounded-xl border border-zinc-200 dark:border-zinc-700 bg-zinc-50 dark:bg-zinc-800/50 p-5">
              <div class="flex items-start gap-5">
                <div class="flex-1 min-w-0">
                  <p class="text-xs font-semibold text-zinc-500 dark:text-zinc-400 uppercase tracking-wider mb-2">Direct access</p>
                  <code class="text-sm font-mono text-zinc-700 dark:text-zinc-300 bg-zinc-100 dark:bg-zinc-950 rounded-lg px-3 py-2 block overflow-x-auto select-all">{@access_url}</code>
                  <p class="text-xs text-zinc-400 dark:text-zinc-500 mt-2">Scan the QR code or open the URL from any device on this network.</p>
                </div>
                <div class="flex-none bg-white p-3 rounded-xl shadow-sm">
                  {raw(@access_qr_svg)}
                </div>
              </div>
            </div>

            <%!-- Status --%>
            <div :if={@interface_up} class="mb-6 rounded-xl border border-green-200 dark:border-green-800 bg-green-50 dark:bg-green-900/20 p-4 flex items-center justify-between">
              <div>
                <div class="flex items-center gap-2 mb-1">
                  <div class="w-2 h-2 rounded-full bg-green-500 animate-pulse"></div>
                  <span class="text-sm font-medium text-green-700 dark:text-green-400">Accepting connections</span>
                </div>
                <p class="text-xs font-mono text-green-600 dark:text-green-500">{WireGuard.server_ip()} — Port {WireGuard.listen_port()}</p>
              </div>
              <button phx-click="toggle_interface" class="text-xs font-medium text-green-600 dark:text-green-400 hover:text-red-500 dark:hover:text-red-400 transition-colors">Stop</button>
            </div>

            <div :if={!@interface_up && @clients != []} class="mb-6 rounded-xl border border-amber-200 dark:border-amber-800 bg-amber-50 dark:bg-amber-900/20 p-4 flex items-center justify-between">
              <div class="flex items-center gap-2">
                <div class="w-2 h-2 rounded-full bg-amber-400"></div>
                <p class="text-sm text-amber-700 dark:text-amber-400">Not accepting connections</p>
              </div>
              <button phx-click="toggle_interface" class="rounded-lg bg-violet-600 hover:bg-violet-700 px-4 py-2 text-sm font-medium text-white transition-colors">Restart</button>
            </div>

            <%!-- Device setup wizard — one step at a time --%>
            <div :if={@new_client} class="mb-6 rounded-xl border border-violet-200 dark:border-violet-800 bg-violet-50 dark:bg-violet-900/20 p-6">
              <div class="flex items-center justify-between mb-5">
                <h3 class="text-lg font-semibold">{@new_client.client["name"]}</h3>
                <button phx-click="dismiss" class="text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-300">
                  <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-5 h-5">
                    <path d="M5.28 4.22a.75.75 0 0 0-1.06 1.06L6.94 8l-2.72 2.72a.75.75 0 1 0 1.06 1.06L8 9.06l2.72 2.72a.75.75 0 1 0 1.06-1.06L9.06 8l2.72-2.72a.75.75 0 0 0-1.06-1.06L8 6.94 5.28 4.22Z" />
                  </svg>
                </button>
              </div>

              <%!-- Step 0: pick platform --%>
              <div :if={!@setup_platform} class="space-y-2">
                <p class="text-sm text-zinc-500 dark:text-zinc-400 mb-4">What device is this?</p>
                <button phx-click="pick_platform" phx-value-platform="iphone" class="w-full text-left rounded-xl border border-zinc-200 dark:border-zinc-700 p-4 hover:border-violet-400 dark:hover:border-violet-500 transition-colors flex items-center gap-3">
                  <span class="text-2xl">📱</span>
                  <div>
                    <p class="text-sm font-medium">iPhone / iPad</p>
                    <p class="text-xs text-zinc-400 dark:text-zinc-500">Scan QR codes to set up</p>
                  </div>
                </button>
                <button phx-click="pick_platform" phx-value-platform="mac" class="w-full text-left rounded-xl border border-zinc-200 dark:border-zinc-700 p-4 hover:border-violet-400 dark:hover:border-violet-500 transition-colors flex items-center gap-3">
                  <span class="text-2xl">💻</span>
                  <div>
                    <p class="text-sm font-medium">Mac</p>
                    <p class="text-xs text-zinc-400 dark:text-zinc-500">Copy config file</p>
                  </div>
                </button>
                <button phx-click="pick_platform" phx-value-platform="linux" class="w-full text-left rounded-xl border border-zinc-200 dark:border-zinc-700 p-4 hover:border-violet-400 dark:hover:border-violet-500 transition-colors flex items-center gap-3">
                  <span class="text-2xl">🐧</span>
                  <div>
                    <p class="text-sm font-medium">Linux</p>
                    <p class="text-xs text-zinc-400 dark:text-zinc-500">Command line setup</p>
                  </div>
                </button>
              </div>

              <%!-- iPhone wizard --%>
              <div :if={@setup_platform == "iphone"}>
                <.wizard_step :if={@setup_step == 1} step={1} total={4} title="Install WireGuard">
                  <p class="text-sm text-zinc-600 dark:text-zinc-400 mb-4">Scan this with your iPhone camera to open the App Store:</p>
                  <div class="flex justify-center">
                    <div class="bg-white p-4 rounded-xl shadow-sm">
                      {raw(@app_qr_svg)}
                    </div>
                  </div>
                </.wizard_step>

                <.wizard_step :if={@setup_step == 2} step={2} total={4} title="Open WireGuard">
                  <p class="text-sm text-zinc-600 dark:text-zinc-400">
                    Open the WireGuard app, tap <strong class="text-zinc-800 dark:text-zinc-200">+</strong> in the top right, then tap <strong class="text-zinc-800 dark:text-zinc-200">Create from QR code</strong>.
                  </p>
                </.wizard_step>

                <.wizard_step :if={@setup_step == 3} step={3} total={4} title="Scan tunnel config">
                  <p class="text-sm text-zinc-600 dark:text-zinc-400 mb-4">Point your phone's camera at this code:</p>
                  <div :if={@new_client.qr_svg} class="flex justify-center">
                    <div class="bg-white p-4 rounded-xl shadow-sm">
                      {raw(@new_client.qr_svg)}
                    </div>
                  </div>
                </.wizard_step>

                <.wizard_step :if={@setup_step == 4} step={4} total={4} title="Connect">
                  <p class="text-sm text-zinc-600 dark:text-zinc-400 mb-2">Toggle the tunnel on in WireGuard, then open:</p>
                  <code class="block text-center text-sm font-mono bg-zinc-100 dark:bg-zinc-950 text-zinc-700 dark:text-zinc-300 rounded-lg px-4 py-3">http://{WireGuard.server_ip()}:4000</code>
                </.wizard_step>
              </div>

              <%!-- Mac wizard --%>
              <div :if={@setup_platform == "mac"}>
                <.wizard_step :if={@setup_step == 1} step={1} total={3} title="Install WireGuard">
                  <p class="text-sm text-zinc-600 dark:text-zinc-400">
                    Download
                    <a href="https://apps.apple.com/app/wireguard/id1451685025" target="_blank" rel="noopener"
                      class="text-violet-600 dark:text-violet-400 underline font-medium">WireGuard</a>
                    from the Mac App Store.
                  </p>
                </.wizard_step>

                <.wizard_step :if={@setup_step == 2} step={2} total={3} title="Import config">
                  <p class="text-sm text-zinc-600 dark:text-zinc-400 mb-3">Copy this config, then in WireGuard choose <strong>Import Tunnel(s) from File</strong>:</p>
                  <pre class="text-xs font-mono bg-zinc-100 dark:bg-zinc-950 text-zinc-700 dark:text-zinc-300 rounded-lg p-4 overflow-x-auto whitespace-pre-wrap">{@new_client.config}</pre>
                  <button id={"copy-wg-mac-#{@new_client.client["name"]}"} phx-hook="CopySource" data-source={@new_client.config}
                    class="mt-2 text-xs font-medium text-violet-600 dark:text-violet-400 hover:text-violet-500">
                    Copy to clipboard
                  </button>
                </.wizard_step>

                <.wizard_step :if={@setup_step == 3} step={3} total={3} title="Connect">
                  <p class="text-sm text-zinc-600 dark:text-zinc-400 mb-2">Activate the tunnel in WireGuard, then open:</p>
                  <code class="block text-center text-sm font-mono bg-zinc-100 dark:bg-zinc-950 text-zinc-700 dark:text-zinc-300 rounded-lg px-4 py-3">http://{WireGuard.server_ip()}:4000</code>
                </.wizard_step>
              </div>

              <%!-- Linux wizard --%>
              <div :if={@setup_platform == "linux"}>
                <.wizard_step :if={@setup_step == 1} step={1} total={3} title="Install WireGuard">
                  <code class="block text-sm font-mono bg-zinc-100 dark:bg-zinc-950 text-zinc-700 dark:text-zinc-300 rounded-lg px-4 py-3">sudo apt install wireguard-tools</code>
                </.wizard_step>

                <.wizard_step :if={@setup_step == 2} step={2} total={3} title="Save config">
                  <p class="text-sm text-zinc-600 dark:text-zinc-400 mb-3">Save this to <code class="text-xs bg-zinc-100 dark:bg-zinc-800 px-1.5 py-0.5 rounded">/etc/wireguard/boomlooper.conf</code>:</p>
                  <pre class="text-xs font-mono bg-zinc-100 dark:bg-zinc-950 text-zinc-700 dark:text-zinc-300 rounded-lg p-4 overflow-x-auto whitespace-pre-wrap">{@new_client.config}</pre>
                  <button id={"copy-wg-linux-#{@new_client.client["name"]}"} phx-hook="CopySource" data-source={@new_client.config}
                    class="mt-2 text-xs font-medium text-violet-600 dark:text-violet-400 hover:text-violet-500">
                    Copy to clipboard
                  </button>
                </.wizard_step>

                <.wizard_step :if={@setup_step == 3} step={3} total={3} title="Connect">
                  <code class="block text-sm font-mono bg-zinc-100 dark:bg-zinc-950 text-zinc-700 dark:text-zinc-300 rounded-lg px-4 py-3 mb-3">sudo wg-quick up boomlooper</code>
                  <p class="text-sm text-zinc-600 dark:text-zinc-400">Then open <span class="font-mono text-xs">http://{WireGuard.server_ip()}:4000</span></p>
                </.wizard_step>
              </div>
            </div>

            <%!-- Device list --%>
            <div class="space-y-2 mb-6">
              <div :for={client <- @clients}
                class="rounded-xl border border-zinc-200 dark:border-zinc-700 p-4 flex items-center justify-between group hover:border-violet-400 dark:hover:border-violet-500 transition-colors">
                <button phx-click="show_client" phx-value-name={client["name"]} class="flex items-center gap-3 min-w-0 flex-1 text-left">
                  <div class="w-2 h-2 rounded-full bg-violet-500 flex-none"></div>
                  <span class="text-sm font-medium">{client["name"]}</span>
                  <span class="text-xs text-zinc-400 dark:text-zinc-500 font-mono">{client["ip"]}</span>
                </button>
                <button phx-click="remove_client" phx-value-name={client["name"]}
                  class="text-zinc-300 dark:text-zinc-600 hover:text-red-500 dark:hover:text-red-400 opacity-0 group-hover:opacity-100 transition-opacity flex-none">
                  <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-4 h-4">
                    <path d="M5.28 4.22a.75.75 0 0 0-1.06 1.06L6.94 8l-2.72 2.72a.75.75 0 1 0 1.06 1.06L8 9.06l2.72 2.72a.75.75 0 1 0 1.06-1.06L9.06 8l2.72-2.72a.75.75 0 0 0-1.06-1.06L8 6.94 5.28 4.22Z" />
                  </svg>
                </button>
              </div>
            </div>

            <%!-- Add device --%>
            <form phx-submit="add_client" class="flex gap-2">
              <input type="text" name="name" placeholder="Device name (e.g. iPhone, MacBook)..." autocomplete="off"
                class="flex-1 rounded-xl border border-zinc-300 dark:border-zinc-600 bg-white dark:bg-zinc-800 px-4 py-3 text-sm
                       text-zinc-600 dark:text-zinc-300 placeholder:text-zinc-400
                       focus:outline-none focus:ring-2 focus:ring-violet-500/20 focus:border-violet-400" />
              <button type="submit"
                class="rounded-xl bg-violet-600 hover:bg-violet-700 px-5 py-3 text-sm font-medium text-white transition-colors flex-none">
                + Add Device
              </button>
            </form>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # --- Components ---

  attr :step, :integer, required: true
  attr :total, :integer, required: true
  attr :title, :string, required: true
  slot :inner_block, required: true

  defp wizard_step(assigns) do
    ~H"""
    <div>
      <p class="text-xs text-zinc-400 dark:text-zinc-500 mb-1">Step {@step} of {@total}</p>
      <h4 class="text-base font-semibold mb-4">{@title}</h4>

      {render_slot(@inner_block)}

      <div class="flex items-center justify-between mt-6">
        <button phx-click="prev_step" class="text-sm text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-300 transition-colors">
          {if @step == 1, do: "Back", else: "Previous"}
        </button>
        <button :if={@step < @total} phx-click="next_step"
          class="rounded-lg bg-violet-600 hover:bg-violet-700 px-5 py-2 text-sm font-medium text-white transition-colors">
          Next
        </button>
        <button :if={@step == @total} phx-click="dismiss"
          class="rounded-lg bg-green-600 hover:bg-green-700 px-5 py-2 text-sm font-medium text-white transition-colors">
          Done
        </button>
      </div>
    </div>
    """
  end
end
