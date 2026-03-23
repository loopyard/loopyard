defmodule BoomLooper.WireGuard do
  @moduledoc """
  Manages WireGuard VPN for secure remote access to BoomLooper.

  Each BoomLooper instance gets its own WireGuard interface with a
  private subnet. Clients (phones, laptops) get a keypair and can
  access all ports on the host — BoomLooper, SSH, Docker service ports.

  Config stored in ~/.boomlooper/wireguard/:
    - server.key / server.pub  — server keypair
    - clients.json             — registered clients
    - wg0.conf                 — generated WireGuard config
  """
  require Logger

  @subnet "10.0.42"
  @server_ip "#{@subnet}.1"
  @listen_port 51820
  @interface "wg0"

  @doc "The WireGuard server IP on the VPN."
  def server_ip, do: @server_ip

  @doc "The WireGuard listen port."
  def listen_port, do: @listen_port

  @doc "The WireGuard interface name."
  def interface, do: @interface

  # --- Setup ---

  @doc "Ensure server keypair exists. Returns {:ok, public_key} or {:error, reason}."
  def ensure_server_keys do
    dir = config_dir()
    File.mkdir_p!(dir)

    key_path = Path.join(dir, "server.key")
    pub_path = Path.join(dir, "server.pub")

    if File.exists?(key_path) do
      {:ok, String.trim(File.read!(pub_path))}
    else
      case generate_keypair() do
        {:ok, private, public} ->
          File.write!(key_path, private)
          File.chmod!(key_path, 0o600)
          File.write!(pub_path, public)
          {:ok, public}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # --- Client management ---

  @doc "List all registered clients."
  def list_clients do
    case File.read(clients_path()) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, clients} -> clients
          _ -> []
        end
      _ -> []
    end
  end

  @doc """
  Add a new client. Returns {:ok, client} with the full client config
  (including private key for the config file / QR code).
  """
  def add_client(name) do
    case generate_keypair() do
      {:ok, private_key, public_key} ->
        clients = list_clients()
        next_ip = next_client_ip(clients)

        client = %{
          "name" => name,
          "public_key" => public_key,
          "private_key" => private_key,
          "ip" => next_ip,
          "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        }

        clients = clients ++ [client]
        save_clients(clients)

        # Regenerate and apply server config
        write_server_config(clients)
        sync_interface()

        {:ok, client}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Remove a client by name."
  def remove_client(name) do
    clients = list_clients()
    clients = Enum.reject(clients, &(&1["name"] == name))
    save_clients(clients)
    write_server_config(clients)
    sync_interface()
    :ok
  end

  @doc "Generate the WireGuard client config file content."
  def client_config(client) do
    {:ok, server_pub} = ensure_server_keys()

    # Detect the host's real IP for the client endpoint
    host_ip = detect_host_ip()

    """
    [Interface]
    PrivateKey = #{client["private_key"]}
    Address = #{client["ip"]}/32
    DNS = #{@server_ip}

    [Peer]
    PublicKey = #{server_pub}
    AllowedIPs = #{@subnet}.0/24
    Endpoint = #{host_ip}:#{@listen_port}
    PersistentKeepalive = 25
    """
  end

  @doc "Generate a QR code SVG for a client config."
  def client_qr_svg(client) do
    config = client_config(client)
    config
    |> EQRCode.encode()
    |> EQRCode.svg(width: 280)
  end

  @doc "Check if WireGuard tools are available."
  def available? do
    System.find_executable("wg") != nil && System.find_executable("wg-quick") != nil
  end

  @doc "Check if the WireGuard interface is up."
  def interface_up? do
    case System.cmd("wg", ["show", @interface], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  @doc "Bring up the WireGuard interface."
  def up do
    config_path = Path.join(config_dir(), "#{@interface}.conf")
    if File.exists?(config_path) do
      System.cmd("wg-quick", ["up", config_path], stderr_to_stdout: true)
    else
      {:error, "No config file. Add a client first."}
    end
  end

  @doc "Bring down the WireGuard interface."
  def down do
    config_path = Path.join(config_dir(), "#{@interface}.conf")
    System.cmd("wg-quick", ["down", config_path], stderr_to_stdout: true)
  end

  # --- Private ---

  defp config_dir do
    Path.join(BoomLooper.Workspace.home_dir(), "wireguard")
  end

  defp clients_path do
    Path.join(config_dir(), "clients.json")
  end

  defp save_clients(clients) do
    File.mkdir_p!(config_dir())
    File.write!(clients_path(), Jason.encode!(clients, pretty: true))
  end

  defp generate_keypair do
    case System.cmd("wg", ["genkey"], stderr_to_stdout: true) do
      {private_key, 0} ->
        private_key = String.trim(private_key)
        case System.cmd("wg", ["pubkey"], input: private_key, stderr_to_stdout: true) do
          {public_key, 0} -> {:ok, private_key, String.trim(public_key)}
          {err, _} -> {:error, "wg pubkey failed: #{err}"}
        end
      {err, _} -> {:error, "wg genkey failed: #{err}"}
    end
  rescue
    e -> {:error, "wg not available: #{Exception.message(e)}"}
  end

  defp next_client_ip(clients) do
    used = Enum.map(clients, fn c ->
      c["ip"]
      |> String.split(".")
      |> List.last()
      |> String.to_integer()
    end)

    # Server is .1, clients start at .2
    next = Enum.reduce_while(2..254, 2, fn i, _acc ->
      if i in used, do: {:cont, i}, else: {:halt, i}
    end)

    "#{@subnet}.#{next}"
  end

  defp write_server_config(clients) do
    ensure_server_keys()
    server_key = String.trim(File.read!(Path.join(config_dir(), "server.key")))

    peers = Enum.map_join(clients, "\n", fn client ->
      """

      [Peer]
      # #{client["name"]}
      PublicKey = #{client["public_key"]}
      AllowedIPs = #{client["ip"]}/32
      """
    end)

    config = """
    [Interface]
    PrivateKey = #{server_key}
    Address = #{@server_ip}/24
    ListenPort = #{@listen_port}
    #{peers}
    """

    path = Path.join(config_dir(), "#{@interface}.conf")
    File.write!(path, config)
    File.chmod!(path, 0o600)
    path
  end

  defp sync_interface do
    config_path = Path.join(config_dir(), "#{@interface}.conf")

    if interface_up?() do
      # Hot-reload: strip config and use wg syncconf
      case System.cmd("wg", ["syncconf", @interface, config_path], stderr_to_stdout: true) do
        {_, 0} -> :ok
        {err, _} -> Logger.warning("[WireGuard] syncconf failed: #{err}")
      end
    end
  rescue
    _ -> :ok
  end

  defp detect_host_ip do
    # Try to get the host's LAN IP
    case System.cmd("hostname", ["-I"], stderr_to_stdout: true) do
      {output, 0} ->
        output |> String.trim() |> String.split() |> hd()
      _ ->
        # macOS fallback
        case System.cmd("ipconfig", ["getifaddr", "en0"], stderr_to_stdout: true) do
          {output, 0} -> String.trim(output)
          _ -> "YOUR_HOST_IP"
        end
    end
  rescue
    _ -> "YOUR_HOST_IP"
  end
end
