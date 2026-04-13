defmodule BoomLooperWeb.ConnectLive do
  use BoomLooperWeb, :live_view
  use BoomLooperWeb.IExAware

  @impl true
  def mount(params, _session, socket) do
    # The "Remote" link passes ?path=/current/page so the QR code
    # takes you to the same page, not just the root.
    path = Map.get(params, "path", "/")

    remote_url = build_remote_url(path)
    qr_svg = remote_url |> EQRCode.encode() |> EQRCode.svg(width: 240)

    lan_ip = detect_lan_ip()
    ssh_cmd = "ssh -p #{BoomLooper.SSHServer.port()} CONTAINER@#{lan_ip}"

    socket = if connected?(socket), do: subscribe_iex(socket), else: assign(socket, :iex_session, %{level: nil})

    {:ok,
     socket
     |> assign(:url, remote_url)
     |> assign(:path, path)
     |> assign(:qr_svg, qr_svg)
     |> assign(:ssh_cmd, ssh_cmd)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-screen flex flex-col bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100">
      <.header breadcrumbs={[{"Boom Looper", "/"}, {"Remote", nil}]} iex_session={@iex_session} />

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
          <p :if={@path != "/"} class="text-xs text-zinc-400 dark:text-zinc-500 mb-4 font-mono truncate max-w-sm">{@path}</p>
          <p class="text-xs text-zinc-400 dark:text-zinc-500">Same Wi-Fi network required</p>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Build a remote-accessible URL for a given path. Uses the LAN IP
  and the server's HTTP port. In the future, this is where tunnel
  URLs (Cloudflare, ngrok) would be resolved instead.
  """
  def build_remote_url(path \\ "/") do
    host = detect_remote_host()
    port = Application.get_env(:boom_looper, BoomLooperWeb.Endpoint)[:http][:port] || 4000

    %URI{scheme: "http", host: host, port: port, path: path}
    |> URI.to_string()
  end

  @doc """
  Detect the best hostname for remote access. Currently returns the
  LAN IP. Future: check for configured tunnel hostname first.
  """
  def detect_remote_host do
    # Future: check for tunnel config first
    # case Application.get_env(:boom_looper, :tunnel_url) do
    #   url when is_binary(url) -> URI.parse(url).host
    #   _ -> detect_lan_ip()
    # end
    detect_lan_ip()
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
