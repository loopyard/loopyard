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

    user_dir = ssh_user_dir()

    ssh_opts = [
      system_dir: String.to_charlist(system_dir),
      user_dir: String.to_charlist(user_dir),
      pwdfun: &check_password/4,
      shell: &start_shell/2,
      no_auth_needed: false,
      auth_methods: ~c"publickey,password",
      idle_time: :infinity
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

  defp user_valid?(container_name), do: container_name != ""

  # --- Shell ---

  # The shell callback is called by Erlang SSH. It must return a pid.
  # The process gets stdin/stdout wired through the Erlang IO system
  # (group leader). We read stdin in a Task and write terminal output
  # to stdout via IO.write.
  defp start_shell(user, _peer) do
    container = to_string(user)
    spawn(fn -> run_shell(container) end)
  end

  defp run_shell(container) do
    case BoomLooper.Terminal.get_or_start(container) do
      {:ok, _pid} ->
        Phoenix.PubSub.subscribe(BoomLooper.PubSub, BoomLooper.Terminal.topic(container))

        # Send buffer for late joiners
        buffer = BoomLooper.Terminal.get_buffer(container)
        if buffer != "", do: IO.write(buffer)

        # Read stdin in a separate process — IO.read blocks
        me = self()
        stdin_reader = spawn_link(fn -> stdin_loop(me) end)

        # Main loop: forward terminal output to stdout, stdin to terminal
        shell_loop(container, stdin_reader)

      {:error, reason} ->
        IO.write("Error: container #{container} not available (#{inspect(reason)})\r\n")
    end
  end

  defp shell_loop(container, stdin_reader) do
    receive do
      {:terminal_output, data} ->
        IO.write(data)
        shell_loop(container, stdin_reader)

      :terminal_clear ->
        IO.write("\e[2J\e[H")
        shell_loop(container, stdin_reader)

      {:terminal_exit, _code} ->
        IO.write("\r\nTerminal session ended.\r\n")

      {:stdin, data} ->
        BoomLooper.Terminal.send_input(container, data)
        shell_loop(container, stdin_reader)

      {:stdin_closed} ->
        :ok

      _ ->
        shell_loop(container, stdin_reader)
    end
  end

  defp stdin_loop(parent) do
    case IO.read(:stdio, 1) do
      {:error, _} -> send(parent, {:stdin_closed})
      :eof -> send(parent, {:stdin_closed})
      data ->
        send(parent, {:stdin, data})
        stdin_loop(parent)
    end
  end

  # --- Host keys ---

  defp ssh_host_key_dir do
    dir = Path.join([System.user_home!(), ".boomlooper", "ssh"])

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

  defp ssh_user_dir do
    dir = Path.join([System.user_home!(), ".boomlooper", "ssh", "user"])
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)

    # Copy the user's authorized_keys so their SSH keys just work
    src = Path.join(System.user_home!(), ".ssh/authorized_keys")
    dest = Path.join(dir, "authorized_keys")

    cond do
      File.exists?(src) ->
        File.cp!(src, dest)

      !File.exists?(dest) ->
        # No authorized_keys — collect all .pub keys from ~/.ssh
        pub_keys = Path.wildcard(Path.join(System.user_home!(), ".ssh/*.pub"))
        if pub_keys != [] do
          content = Enum.map_join(pub_keys, "\n", &File.read!/1)
          File.write!(dest, content)
        end
    end

    dir
  end

  defp generate_host_key(dir, :ecdsa) do
    ec_key = :public_key.generate_key({:namedCurve, :secp256r1})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:ECPrivateKey, ec_key)])
    path = Path.join(dir, "ssh_host_ecdsa_key")
    File.write!(path, pem)
    File.chmod!(path, 0o600)
  end
end
