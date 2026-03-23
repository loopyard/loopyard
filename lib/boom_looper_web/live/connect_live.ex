defmodule BoomLooperWeb.ConnectLive do
  use BoomLooperWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    lan_ip = detect_lan_ip()
    port = Application.get_env(:boom_looper, BoomLooperWeb.Endpoint)[:http][:port] || 4000
    url = "http://#{lan_ip}:#{port}"
    qr_svg = url |> EQRCode.encode() |> EQRCode.svg(width: 240)

    ssh_cmd = "ssh -p #{BoomLooper.SSHServer.port()} CONTAINER@#{lan_ip}"

    {:ok,
     socket
     |> assign(:url, url)
     |> assign(:qr_svg, qr_svg)
     |> assign(:ssh_cmd, ssh_cmd)}
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

      <div class="flex-1 flex items-center justify-center">
        <div class="text-center px-4">
          <div class="bg-white p-5 rounded-2xl shadow-sm inline-block mb-6">
            {raw(@qr_svg)}
          </div>
          <p class="text-sm text-zinc-500 dark:text-zinc-400 mb-2">Scan to open on your phone</p>
          <div class="flex items-center justify-center gap-2 mb-6">
            <code class="text-sm font-mono text-zinc-700 dark:text-zinc-300 bg-zinc-100 dark:bg-zinc-800 rounded-lg px-3 py-2 select-all">{@url}</code>
            <button id="copy-url" phx-hook="CopySource" data-source={@url}
              class="text-xs text-violet-600 dark:text-violet-400 hover:text-violet-500 font-medium">Copy</button>
          </div>
          <p class="text-xs text-zinc-400 dark:text-zinc-500">Same Wi-Fi network required</p>
        </div>
      </div>
    </div>
    """
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
