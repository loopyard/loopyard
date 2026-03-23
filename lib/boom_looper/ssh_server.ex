defmodule BoomLooper.SSHServer do
  @moduledoc """
  SSH server for terminal access to Docker containers.
  Username is the container name. No password.

    ssh -p 2222 container-name@localhost

  Multiplayer — SSH sessions share the same Terminal GenServer as
  browser console tabs. All viewers see the same terminal.
  """
  require Logger

  @default_port 2222

  def start_link(opts \\ []) do
    port = Keyword.get(opts, :port, @default_port)
    system_dir = ssh_host_key_dir()

    :ssh.start()

    ssh_opts = [
      system_dir: String.to_charlist(system_dir),
      shell: &start_shell/2,
      no_auth_needed: true,
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
  rescue
    e ->
      Logger.error("[SSHServer] Failed to start: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  @doc "The SSH port number."
  def port, do: @default_port

  # --- Shell ---

  defp start_shell(user, _peer) do
    container = to_string(user)
    spawn(fn -> run_shell(container) end)
  end

  defp run_shell(container) do
    case BoomLooper.Terminal.get_or_start(container) do
      {:ok, _pid} ->
        Phoenix.PubSub.subscribe(BoomLooper.PubSub, BoomLooper.Terminal.topic(container))

        buffer = BoomLooper.Terminal.get_buffer(container)
        if buffer != "", do: IO.write(buffer)

        me = self()
        _stdin_reader = spawn_link(fn -> stdin_loop(me) end)

        shell_loop(container)

      {:error, reason} ->
        IO.write("Error: container #{container} not available (#{inspect(reason)})\r\n")
    end
  end

  defp shell_loop(container) do
    receive do
      {:terminal_output, data} ->
        IO.write(data)
        shell_loop(container)

      :terminal_clear ->
        IO.write("\e[2J\e[H")
        shell_loop(container)

      {:terminal_exit, _code} ->
        IO.write("\r\nTerminal session ended.\r\n")

      {:stdin, data} ->
        BoomLooper.Terminal.send_input(container, data)
        shell_loop(container)

      {:stdin_closed} ->
        :ok

      _ ->
        shell_loop(container)
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
    dir = Path.join(BoomLooper.Workspace.home_dir(), "ssh")

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
