defmodule BoomLooperWeb.WireGuardLive do
  use BoomLooperWeb, :live_view

  alias BoomLooper.WireGuard

  @impl true
  def mount(_params, _session, socket) do
    available = WireGuard.available?()
    clients = if available, do: WireGuard.list_clients(), else: []
    interface_up = if available, do: WireGuard.interface_up?(), else: false

    {:ok,
     socket
     |> assign(:available, available)
     |> assign(:clients, clients)
     |> assign(:interface_up, interface_up)
     |> assign(:new_client, nil)}
  end

  @impl true
  def handle_event("add_client", %{"name" => name}, socket) do
    name = String.trim(name)

    if name != "" do
      case WireGuard.add_client(name) do
        {:ok, client} ->
          config = WireGuard.client_config(client)
          qr_svg = try do
            WireGuard.client_qr_svg(client)
          rescue
            _ -> nil
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
      qr_svg = try do
        WireGuard.client_qr_svg(client)
      rescue
        _ -> nil
      end

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
  def handle_event("dismiss", _params, socket) do
    {:noreply, assign(socket, :new_client, nil)}
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
            <p class="text-sm text-zinc-500 dark:text-zinc-400 mb-2">WireGuard is not installed.</p>
            <code class="text-xs text-zinc-400 dark:text-zinc-500 bg-zinc-100 dark:bg-zinc-800 px-3 py-1.5 rounded-lg">brew install wireguard-tools</code>
          </div>

          <div :if={@available}>
            <div class="flex items-center justify-between mb-6">
              <div>
                <h2 class="text-xl font-semibold">Remote Access</h2>
                <p class="text-sm text-zinc-500 dark:text-zinc-400 mt-0.5">
                  Connect devices to access all ports on this machine.
                </p>
              </div>
              <button phx-click="toggle_interface"
                class={"rounded-lg px-4 py-2 text-sm font-medium transition-colors #{if @interface_up, do: "bg-green-100 dark:bg-green-900/30 text-green-700 dark:text-green-400", else: "bg-zinc-100 dark:bg-zinc-800 text-zinc-600 dark:text-zinc-400"}"}>
                {if @interface_up, do: "Connected", else: "Start"}
              </button>
            </div>

            <div :if={@interface_up} class="mb-6 rounded-xl border border-green-200 dark:border-green-800 bg-green-50 dark:bg-green-900/20 p-4">
              <div class="flex items-center gap-2 mb-1">
                <div class="w-2 h-2 rounded-full bg-green-500"></div>
                <span class="text-sm font-medium text-green-700 dark:text-green-400">Active</span>
              </div>
              <p class="text-xs font-mono text-green-600 dark:text-green-500">
                {WireGuard.server_ip()} — Port {WireGuard.listen_port()}
              </p>
            </div>

            <%!-- New client detail — shown immediately after add or when clicking a client --%>
            <div :if={@new_client} class="mb-6 rounded-xl border border-violet-200 dark:border-violet-800 bg-violet-50 dark:bg-violet-900/20 p-6">
              <div class="flex items-center justify-between mb-4">
                <div>
                  <h3 class="text-lg font-semibold">{@new_client.client["name"]}</h3>
                  <p class="text-xs font-mono text-zinc-400">{@new_client.client["ip"]}</p>
                </div>
                <button phx-click="dismiss" class="text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-300">
                  <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-5 h-5">
                    <path d="M5.28 4.22a.75.75 0 0 0-1.06 1.06L6.94 8l-2.72 2.72a.75.75 0 1 0 1.06 1.06L8 9.06l2.72 2.72a.75.75 0 1 0 1.06-1.06L9.06 8l2.72-2.72a.75.75 0 0 0-1.06-1.06L8 6.94 5.28 4.22Z" />
                  </svg>
                </button>
              </div>

              <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
                <%!-- QR Code for phone --%>
                <div :if={@new_client.qr_svg} class="flex flex-col items-center">
                  <p class="text-xs text-zinc-500 dark:text-zinc-400 mb-3">Scan with WireGuard app</p>
                  <div class="bg-white p-4 rounded-xl shadow-sm">
                    {raw(@new_client.qr_svg)}
                  </div>
                </div>

                <%!-- Config --%>
                <div>
                  <p class="text-xs text-zinc-500 dark:text-zinc-400 mb-3">Or import this config file</p>
                  <pre class="text-xs font-mono bg-zinc-100 dark:bg-zinc-950 text-zinc-700 dark:text-zinc-300 rounded-lg p-4 overflow-x-auto whitespace-pre-wrap">{@new_client.config}</pre>
                  <button id={"copy-wg-#{@new_client.client["name"]}"} phx-hook="CopySource" data-source={@new_client.config}
                    class="mt-2 text-xs font-medium text-violet-600 dark:text-violet-400 hover:text-violet-500">
                    Copy to clipboard
                  </button>
                </div>
              </div>

              <p class="mt-4 text-xs text-zinc-400 dark:text-zinc-500">
                After connecting, open
                <span class="font-mono">http://{WireGuard.server_ip()}:4000</span>
              </p>
            </div>

            <%!-- Client list --%>
            <div class="space-y-2 mb-6">
              <div :for={client <- @clients}
                class="rounded-xl border border-zinc-200 dark:border-zinc-700 p-4 flex items-center justify-between group hover:border-violet-400 dark:hover:border-violet-500 transition-colors">
                <button phx-click="show_client" phx-value-name={client["name"]} class="flex items-center gap-3 min-w-0 flex-1 text-left">
                  <div class="w-2 h-2 rounded-full bg-violet-500 flex-none"></div>
                  <div class="min-w-0">
                    <span class="text-sm font-medium">{client["name"]}</span>
                    <span class="text-xs text-zinc-400 dark:text-zinc-500 ml-2 font-mono">{client["ip"]}</span>
                  </div>
                </button>
                <button phx-click="remove_client" phx-value-name={client["name"]}
                  class="text-zinc-300 dark:text-zinc-600 hover:text-red-500 dark:hover:text-red-400 opacity-0 group-hover:opacity-100 transition-opacity flex-none">
                  <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-4 h-4">
                    <path d="M5.28 4.22a.75.75 0 0 0-1.06 1.06L6.94 8l-2.72 2.72a.75.75 0 1 0 1.06 1.06L8 9.06l2.72 2.72a.75.75 0 1 0 1.06-1.06L9.06 8l2.72-2.72a.75.75 0 0 0-1.06-1.06L8 6.94 5.28 4.22Z" />
                  </svg>
                </button>
              </div>
            </div>

            <%!-- Add client form --%>
            <form phx-submit="add_client" class="flex gap-2">
              <input type="text" name="name" placeholder="Device name (e.g. iPhone, Laptop)..." autocomplete="off"
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
end
