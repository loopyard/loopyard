defmodule Loopyard.SSHServer.Channel do
  @moduledoc """
  SSH channel that provides raw byte I/O to a shared Terminal session.

  Implements `:ssh_server_channel` behavior for direct access to the
  SSH data stream — no line buffering, no group leader, every keystroke
  delivered immediately. Same behavior as the websocket terminal channel.

  Lifecycle:
  1. `ssh_channel_up` — extracts container name from SSH username,
     connects to Terminal GenServer, subscribes to PubSub
  2. `{:data, ...}` — forwards keystrokes to Terminal.send_input
  3. `{:terminal_output, ...}` — sends Terminal output to SSH client
  4. `{:closed, ...}` — cleanup
  """
  @behaviour :ssh_server_channel

  alias Loopyard.Events
  alias Loopyard.Terminal

  # Ctrl+L (form feed) — clear screen signal
  @ctrl_l <<12>>

  defstruct [:connection, :channel_id, :container]

  @doc "Check if input data contains a clear-screen signal (Ctrl+L)."
  def clear_signal?(data), do: data == @ctrl_l

  # --- Callbacks ---

  @impl true
  def init(_args) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_ssh_msg({:ssh_cm, conn, {:pty, chan, want_reply, _opts}}, state) do
    ack(conn, chan, want_reply)
    {:ok, state}
  end

  def handle_ssh_msg({:ssh_cm, conn, {:shell, chan, want_reply}}, state) do
    ack(conn, chan, want_reply)
    {:ok, state}
  end

  def handle_ssh_msg({:ssh_cm, conn, {:env, chan, want_reply, _var, _val}}, state) do
    ack(conn, chan, want_reply)
    {:ok, state}
  end

  def handle_ssh_msg({:ssh_cm, _conn, {:window_change, _chan, _w, _h, _pw, _ph}}, state) do
    {:ok, state}
  end

  def handle_ssh_msg({:ssh_cm, _conn, {:data, _chan, _type, data}}, state) do
    if state.container do
      if clear_signal?(data), do: Terminal.clear_buffer(state.container)
      Terminal.send_input(state.container, data)
    end

    {:ok, state}
  end

  def handle_ssh_msg({:ssh_cm, _conn, {:eof, _chan}}, state) do
    {:ok, state}
  end

  def handle_ssh_msg({:ssh_cm, _conn, {:closed, _chan}}, state) do
    {:stop, state.channel_id, state}
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
    state = connect_terminal(state)
    {:ok, state}
  end

  def handle_msg(%Events.Terminal.Output{data: data}, state) do
    send_data(state, data)
    {:ok, state}
  end

  def handle_msg(%Events.Terminal.Clear{}, state) do
    send_data(state, "\e[2J\e[H")
    {:ok, state}
  end

  def handle_msg(%Events.Terminal.Exit{}, state) do
    send_data(state, "\r\nTerminal session ended.\r\n")

    if state.connection && state.channel_id do
      :ssh_connection.close(state.connection, state.channel_id)
    end

    {:stop, state.channel_id, state}
  end

  def handle_msg(_msg, state) do
    {:ok, state}
  end

  @impl true
  def terminate(_reason, _state), do: :ok

  # --- Private ---

  defp connect_terminal(state) do
    case Terminal.get_or_start(state.container) do
      {:ok, _pid} ->
        Events.Terminal.subscribe(state.container)

        buffer = Terminal.get_buffer(state.container)
        if buffer != "", do: send_data(state, buffer)

        state

      {:error, reason} ->
        send_data(state, "Error: #{state.container} not available (#{inspect(reason)})\r\n")
        state
    end
  end

  defp ack(conn, chan, want_reply) do
    if want_reply, do: :ssh_connection.reply_request(conn, want_reply, :success, chan)
  end

  defp send_data(%{connection: conn, channel_id: chan}, data) when conn != nil and chan != nil do
    :ssh_connection.send(conn, chan, data)
  end

  defp send_data(_, _), do: :ok
end
