defmodule BoomLooperWeb.ConnectLive do
  use BoomLooperWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    lan_enabled = Application.get_env(:boom_looper, :lan_enabled, false)
    ssh_enabled = Application.get_env(:boom_looper, :ssh_enabled, false)
    lan_ip = detect_lan_ip()
    port = Application.get_env(:boom_looper, BoomLooperWeb.Endpoint)[:http][:port] || 4000
    url = "http://#{lan_ip}:#{port}"

    qr_svg = if lan_enabled do
      url |> EQRCode.encode() |> EQRCode.svg(width: 240)
    end

    {:ok,
     socket
     |> assign(:lan_enabled, lan_enabled)
     |> assign(:ssh_enabled, ssh_enabled)
     |> assign(:lan_ip, lan_ip)
     |> assign(:port, port)
     |> assign(:url, url)
     |> assign(:qr_svg, qr_svg)
     |> assign(:ssh_port, BoomLooper.SSHServer.port())}
  end

  @impl true
  def handle_event("toggle_lan", _params, socket) do
    if socket.assigns.lan_enabled do
      disable_lan()
      {:noreply,
       socket
       |> assign(:lan_enabled, false)
       |> assign(:qr_svg, nil)
       |> put_flash(:info, "LAN access disabled. Restart the server to take effect.")}
    else
      enable_lan()
      qr_svg = socket.assigns.url |> EQRCode.encode() |> EQRCode.svg(width: 240)
      {:noreply,
       socket
       |> assign(:lan_enabled, true)
       |> assign(:qr_svg, qr_svg)
       |> put_flash(:info, "LAN access enabled. Restart the server to take effect.")}
    end
  end

  @impl true
  def handle_event("toggle_ssh", _params, socket) do
    flag_path = Path.join(BoomLooper.Workspace.home_dir(), "ssh_enabled")

    if socket.assigns.ssh_enabled do
      Application.put_env(:boom_looper, :ssh_enabled, false)
      File.rm(flag_path)
      {:noreply,
       socket
       |> assign(:ssh_enabled, false)
       |> put_flash(:info, "SSH disabled. Restart the server to take effect.")}
    else
      Application.put_env(:boom_looper, :ssh_enabled, true)
      File.mkdir_p!(Path.dirname(flag_path))
      File.write!(flag_path, "")

      # Try to start SSH now
      case BoomLooper.SSHServer.start_link() do
        {:ok, _} -> :ok
        {:error, _} -> :ok
      end

      {:noreply,
       socket
       |> assign(:ssh_enabled, true)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-screen flex flex-col bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100">
      <header class="flex-none h-14 border-b border-zinc-200 dark:border-zinc-700/80 flex items-center px-4 md:px-5 gap-3">
        <.link navigate="/" class="text-lg font-semibold tracking-tight hover:text-violet-600 dark:hover:text-violet-400 transition-colors">Boom Looper</.link>
        <span class="text-zinc-300 dark:text-zinc-600">/</span>
        <span class="text-sm font-medium">Connect</span>
      </header>

      <div class="flex-1 overflow-y-auto">
        <div class="max-w-lg mx-auto px-4 py-8">
          <p :if={@flash["info"]} class="mb-4 rounded-lg bg-blue-50 dark:bg-blue-900/20 border border-blue-200 dark:border-blue-800 px-4 py-3 text-sm text-blue-700 dark:text-blue-300">
            {@flash["info"]}
          </p>

          <%!-- LAN Access --%>
          <div class="mb-8">
            <div class="flex items-center justify-between mb-4">
              <div>
                <h2 class="text-lg font-semibold">LAN Access</h2>
                <p class="text-sm text-zinc-500 dark:text-zinc-400">Let devices on your Wi-Fi open BoomLooper</p>
              </div>
              <button phx-click="toggle_lan"
                class={"relative inline-flex h-6 w-11 items-center rounded-full transition-colors " <>
                  if(@lan_enabled, do: "bg-violet-600", else: "bg-zinc-300 dark:bg-zinc-600")}
                role="switch" aria-checked={@lan_enabled}>
                <span class={"inline-block h-4 w-4 rounded-full bg-white transition-transform " <>
                  if(@lan_enabled, do: "translate-x-6", else: "translate-x-1")} />
              </button>
            </div>

            <div :if={@lan_enabled && @qr_svg} class="text-center">
              <div class="bg-white p-5 rounded-2xl shadow-sm inline-block mb-4">
                {raw(@qr_svg)}
              </div>
              <p class="text-sm text-zinc-500 dark:text-zinc-400 mb-2">Scan to open on your phone</p>
              <div class="flex items-center justify-center gap-2">
                <code class="text-sm font-mono text-zinc-700 dark:text-zinc-300 bg-zinc-100 dark:bg-zinc-800 rounded-lg px-3 py-2 select-all">{@url}</code>
                <button id="copy-url" phx-hook="CopySource" data-source={@url}
                  class="text-xs text-violet-600 dark:text-violet-400 hover:text-violet-500 font-medium">
                  Copy
                </button>
              </div>
              <p class="text-xs text-zinc-400 dark:text-zinc-500 mt-3">Same Wi-Fi network required</p>
            </div>
          </div>

          <%!-- SSH --%>
          <div class="border-t border-zinc-200 dark:border-zinc-700 pt-8">
            <div class="flex items-center justify-between mb-2">
              <div>
                <h2 class="text-lg font-semibold">SSH</h2>
                <p class="text-sm text-zinc-500 dark:text-zinc-400">Terminal access to containers via SSH</p>
              </div>
              <button phx-click="toggle_ssh"
                class={"relative inline-flex h-6 w-11 items-center rounded-full transition-colors " <>
                  if(@ssh_enabled, do: "bg-violet-600", else: "bg-zinc-300 dark:bg-zinc-600")}
                role="switch" aria-checked={@ssh_enabled}>
                <span class={"inline-block h-4 w-4 rounded-full bg-white transition-transform " <>
                  if(@ssh_enabled, do: "translate-x-6", else: "translate-x-1")} />
              </button>
            </div>
            <div :if={@ssh_enabled} class="mt-3 rounded-xl bg-zinc-50 dark:bg-zinc-800/50 border border-zinc-200 dark:border-zinc-700 p-4">
              <p class="text-xs text-zinc-500 dark:text-zinc-400 mb-2">Connect to any container:</p>
              <code class="text-sm font-mono text-zinc-700 dark:text-zinc-300 bg-zinc-100 dark:bg-zinc-950 rounded-lg px-3 py-2 block">ssh -p {@ssh_port} CONTAINER@{if @lan_enabled, do: @lan_ip, else: "localhost"}</code>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp enable_lan do
    Application.put_env(:boom_looper, :lan_enabled, true)
    flag_path = Path.join(BoomLooper.Workspace.home_dir(), "lan_enabled")
    File.mkdir_p!(Path.dirname(flag_path))
    File.write!(flag_path, "")
  end

  defp disable_lan do
    Application.put_env(:boom_looper, :lan_enabled, false)
    flag_path = Path.join(BoomLooper.Workspace.home_dir(), "lan_enabled")
    File.rm(flag_path)
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
