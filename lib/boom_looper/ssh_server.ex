defmodule BoomLooper.SSHServer do
  @moduledoc """
  SSH server that provides terminal access to Docker containers.
  Username is the container name, password is the launch secret.

  Multiplayer — SSH sessions share the same Terminal GenServer as
  browser console tabs. All viewers see the same terminal.

  Start: automatically started in application.ex
  Connect: ssh container-name@localhost -p 2222
  """
  require Logger

  @default_port 2222

  def start_link(opts \\ []) do
    port = Keyword.get(opts, :port, @default_port)
    system_dir = ssh_host_key_dir()

    :ssh.start()

    ssh_opts = [
      system_dir: String.to_charlist(system_dir),
      pwdfun: &check_password/4,
      shell: &start_shell/2,
      no_auth_needed: false,
      auth_methods: ~c"password",
      idle_time: :infinity,
      disconnectfun: fn _reason -> :ok end
    ]

    case :ssh.daemon(port, ssh_opts) do
      {:ok, pid} ->
        Logger.info("[SSHServer] Listening on port #{port}")
        {:ok, pid}

      {:error, reason} ->
        Logger.error("[SSHServer] Failed to start: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc "The SSH port number."
  def port, do: @default_port

  # --- Auth ---

  defp check_password(user, password, _peer_address, _state) do
    expected = Application.get_env(:boom_looper, :launch_secret, "")
    Plug.Crypto.secure_compare(to_string(password), expected) && user_valid?(to_string(user))
  end

  defp user_valid?(container_name) do
    # Container name must be non-empty. We don't validate it exists here —
    # Terminal.get_or_start will fail if the container isn't running.
    container_name != ""
  end

  # --- Shell ---

  defp start_shell(user, _peer) do
    container = to_string(user)
    spawn(fn -> run_shell(container) end)
  end

  defp run_shell(container) do
    case BoomLooper.Terminal.get_or_start(container) do
      {:ok, _pid} ->
        # Subscribe to terminal output
        Phoenix.PubSub.subscribe(BoomLooper.PubSub, BoomLooper.Terminal.topic(container))

        # Send buffer for late joiners
        buffer = BoomLooper.Terminal.get_buffer(container)
        if buffer != "", do: send_to_ssh(buffer)

        # I/O loop
        ssh_loop(container)

      {:error, reason} ->
        send_to_ssh("Error: container #{container} not available (#{inspect(reason)})\r\n")
    end
  end

  defp ssh_loop(container) do
    receive do
      {:terminal_output, data} ->
        send_to_ssh(data)
        ssh_loop(container)

      :terminal_clear ->
        # Send ANSI clear screen
        send_to_ssh("\e[2J\e[H")
        ssh_loop(container)

      {:ssh_cm, _conn, {:data, _channel, _type, data}} ->
        BoomLooper.Terminal.send_input(container, data)
        ssh_loop(container)

      {:ssh_cm, _conn, {:eof, _channel}} ->
        :ok

      {:ssh_cm, _conn, {:closed, _channel}} ->
        :ok

      {:terminal_exit, _code} ->
        send_to_ssh("\r\nTerminal session ended.\r\n")

      _ ->
        ssh_loop(container)
    end
  end

  defp send_to_ssh(data) do
    # In an SSH shell process, stdout goes to the group leader
    IO.write(data)
  end

  # --- Host keys ---

  defp ssh_host_key_dir do
    dir = Path.join(System.tmp_dir!(), "boom-looper-ssh-keys")

    unless File.exists?(Path.join(dir, "ssh_host_rsa_key")) do
      File.mkdir_p!(dir)
      File.chmod!(dir, 0o700)
      generate_host_key(dir, :rsa)
      generate_host_key(dir, :ecdsa)
    end

    dir
  end

  defp generate_host_key(dir, :rsa) do
    rsa_key = :public_key.generate_key({:rsa, 2048, 65537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, rsa_key)])
    path = Path.join(dir, "ssh_host_rsa_key")
    File.write!(path, pem)
    File.chmod!(path, 0o600)
  end

  defp generate_host_key(dir, :ecdsa) do
    ec_key = :public_key.generate_key({:namedCurve, :secp256r1})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:ECPrivateKey, ec_key)])
    path = Path.join(dir, "ssh_host_ecdsa_key")
    File.write!(path, pem)
    File.chmod!(path, 0o600)
  end
end
