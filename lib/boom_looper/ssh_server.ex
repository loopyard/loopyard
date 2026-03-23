defmodule BoomLooper.SSHServer do
  @moduledoc """
  SSH server for terminal access to Docker containers.
  Username is the container name. No password.

    ssh -p 2222 container-name@localhost

  Multiplayer — SSH sessions share the same Terminal GenServer as
  browser console tabs. All viewers see the same terminal.

  Uses `ssh_server_channel` behavior for raw byte access — every
  keystroke arrives immediately (no line buffering), same as the
  websocket path.
  """
  require Logger

  @default_port 2222

  def start_link(opts \\ []) do
    port = Keyword.get(opts, :port, @default_port)
    system_dir = ssh_host_key_dir()

    :ssh.start()

    ssh_opts = [
      system_dir: String.to_charlist(system_dir),
      ssh_cli: {BoomLooper.SSHServer.Channel, []},
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

defmodule BoomLooper.SSHServer.Channel do
  @moduledoc """
  SSH channel that provides raw byte I/O to a Terminal session.
  Implements :ssh_server_channel behavior for direct access to the
  SSH data stream — no line buffering, no group leader, every
  keystroke delivered immediately.
  """
  @behaviour :ssh_server_channel

  alias BoomLooper.Terminal

  defstruct [:connection, :channel_id, :container]

  @impl true
  def init(_args) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_ssh_msg({:ssh_cm, connection, {:pty, channel_id, want_reply, _pty_opts}}, state) do
    if want_reply, do: :ssh_connection.reply_request(connection, want_reply, :success, channel_id)
    {:ok, state}
  end

  # Client requests a shell — start the terminal session
  def handle_ssh_msg({:ssh_cm, connection, {:shell, channel_id, want_reply}}, state) do
    if want_reply, do: :ssh_connection.reply_request(connection, want_reply, :success, channel_id)
    {:ok, state}
  end

  # Client sends "env" — ignore but acknowledge
  def handle_ssh_msg({:ssh_cm, connection, {:env, channel_id, want_reply, _var, _val}}, state) do
    if want_reply, do: :ssh_connection.reply_request(connection, want_reply, :success, channel_id)
    {:ok, state}
  end

  # Client sends "window_change" — ignore for now
  def handle_ssh_msg({:ssh_cm, _connection, {:window_change, _channel_id, _width, _height, _px_w, _px_h}}, state) do
    {:ok, state}
  end

  # Client sends data (keystrokes) — raw, byte by byte
  def handle_ssh_msg({:ssh_cm, _connection, {:data, _channel_id, _type, data}}, state) do
    if state.container do
      Terminal.send_input(state.container, data)
    end
    {:ok, state}
  end

  # Client sends EOF
  def handle_ssh_msg({:ssh_cm, _connection, {:eof, _channel_id}}, state) do
    {:ok, state}
  end

  # Client closes channel
  def handle_ssh_msg({:ssh_cm, _connection, {:closed, _channel_id}}, state) do
    {:stop, _channel_id = state.channel_id, state}
  end

  # Exec request — username comes through here or via the connection
  def handle_ssh_msg({:ssh_cm, connection, {:exec, channel_id, want_reply, command}}, state) do
    container = to_string(command)

    if want_reply, do: :ssh_connection.reply_request(connection, want_reply, :success, channel_id)

    state = start_terminal_session(container, state)
    {:ok, state}
  end

  def handle_ssh_msg(_msg, state) do
    {:ok, state}
  end

  # --- handle_msg: SSH lifecycle + PubSub from Terminal ---

  @impl true
  def handle_msg({:ssh_channel_up, channel_id, connection}, state) do
    [{:user, user} | _] = :ssh.connection_info(connection, [:user])
    container = to_string(user)

    state = %{state | connection: connection, channel_id: channel_id, container: container}
    state = start_terminal_session(container, state)
    {:ok, state}
  end

  def handle_msg({:terminal_output, data}, state) do
    if state.connection && state.channel_id do
      :ssh_connection.send(state.connection, state.channel_id, data)
    end
    {:ok, state}
  end

  def handle_msg(:terminal_clear, state) do
    if state.connection && state.channel_id do
      :ssh_connection.send(state.connection, state.channel_id, "\e[2J\e[H")
    end
    {:ok, state}
  end

  def handle_msg({:terminal_exit, _code}, state) do
    if state.connection && state.channel_id do
      :ssh_connection.send(state.connection, state.channel_id, "\r\nTerminal session ended.\r\n")
      :ssh_connection.close(state.connection, state.channel_id)
    end
    {:stop, state.channel_id, state}
  end

  # Catch-all for unknown messages (SSH internals, monitors, etc.)
  def handle_msg(_msg, state) do
    {:ok, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :ok
  end

  # --- Private ---

  defp start_terminal_session(container, state) do
    case Terminal.get_or_start(container) do
      {:ok, _pid} ->
        Phoenix.PubSub.subscribe(BoomLooper.PubSub, Terminal.topic(container))

        buffer = Terminal.get_buffer(container)
        if buffer != "" && state.connection && state.channel_id do
          :ssh_connection.send(state.connection, state.channel_id, buffer)
        end

        %{state | container: container}

      {:error, reason} ->
        if state.connection && state.channel_id do
          msg = "Error: container #{container} not available (#{inspect(reason)})\r\n"
          :ssh_connection.send(state.connection, state.channel_id, msg)
        end
        state
    end
  end
end
