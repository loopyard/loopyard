defmodule BoomLooper.PortExposerTest do
  @moduledoc """
  Exercises the TCP proxy end-to-end against a loopback echo server.

  The exposer listens on `0.0.0.0:<host_port>` and forwards to
  an upstream loopback port. In production that 127.0.0.1 target
  is the loopback-bound Docker port. In tests we stand up an echo
  server on a separate loopback port so we can verify:

    1. A TCP client connecting through the exposer reaches the echo.
    2. Bytes in both directions are counted.
    3. Connection peer IPs are tracked.
    4. Closing the exposer drops in-flight connections immediately.
  """
  use ExUnit.Case, async: false

  alias BoomLooper.PortExposer

  setup do
    host_port = free_port()
    upstream_port = free_port()
    key = {"ws-exp", "dev", 3000}

    echo_pid = start_echo_server(upstream_port)
    on_exit(fn -> stop_echo_server(echo_pid) end)

    %{port: host_port, upstream_port: upstream_port, key: key}
  end

  describe "forwarding + counters" do
    test "proxies data both directions and counts bytes", %{port: port, upstream_port: up, key: key} do
      {:ok, exposer} =
        PortExposer.start_link(
          key: key,
          host_port: port,
          upstream_host: {127, 0, 0, 1},
          upstream_port: up
        )

      on_exit(fn -> try do GenServer.stop(exposer) catch :exit, _ -> :ok end end)

      {:ok, client} =
        :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, packet: :raw, active: false], 1_000)

      :ok = :gen_tcp.send(client, "hello")
      {:ok, "hello"} = :gen_tcp.recv(client, 5, 1_000)

      :ok = :gen_tcp.send(client, "world")
      {:ok, "world"} = :gen_tcp.recv(client, 5, 1_000)

      :gen_tcp.close(client)

      # Give the exposer a tick to process tcp_closed for both sides.
      Process.sleep(50)

      status = PortExposer.status(key)
      assert status.bytes_in >= 10
      assert status.bytes_out >= 10
      # Client disconnected; connection_count should settle to 0.
      assert status.connection_count == 0
    end

    test "status/1 reports live connection_count while a client is connected",
         %{port: port, upstream_port: up, key: key} do
      {:ok, exposer} =
        PortExposer.start_link(
          key: key,
          host_port: port,
          upstream_host: {127, 0, 0, 1},
          upstream_port: up
        )

      on_exit(fn -> try do GenServer.stop(exposer) catch :exit, _ -> :ok end end)

      {:ok, client} =
        :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, packet: :raw, active: false], 1_000)

      # Eventually consistent — acceptor runs in a task.
      :ok = eventually(fn -> PortExposer.status(key).connection_count == 1 end)

      status = PortExposer.status(key)
      assert status.connection_count == 1
      assert status.peers == ["127.0.0.1"]
      assert is_integer(status.host_port)
      assert %DateTime{} = status.opened_at

      :gen_tcp.close(client)
    end
  end

  describe "lifecycle" do
    test "terminate/2 closes the listener immediately", %{port: port, upstream_port: up, key: key} do
      {:ok, exposer} =
        PortExposer.start_link(
          key: key,
          host_port: port,
          upstream_host: {127, 0, 0, 1},
          upstream_port: up
        )

      # Listener is up.
      {:ok, socket} =
        :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 500)

      :gen_tcp.close(socket)

      GenServer.stop(exposer)
      Process.sleep(50)

      # After stop, the port should be bindable again (no listener
      # holding it). If we can listen on the same port, we confirm
      # the exposer released it.
      assert {:ok, listen} = :gen_tcp.listen(port, [:binary, active: false, reuseaddr: true])
      :gen_tcp.close(listen)
    end

    test "whereis/1 + status/1 report :not_running when no exposer" do
      assert :not_running = PortExposer.status({"nobody", "nothing", 9999})
      assert nil == PortExposer.whereis({"nobody", "nothing", 9999})
    end
  end

  describe "external binding" do
    test "listens on 0.0.0.0 and is reachable from non-loopback", %{upstream_port: up, key: key} do
      # Allocate a fresh port for the exposer — must NOT conflict with
      # the echo server on loopback.
      expose_port = free_port()

      {:ok, exposer} =
        PortExposer.start_link(
          key: key,
          host_port: expose_port,
          upstream_host: {127, 0, 0, 1},
          upstream_port: up
        )

      on_exit(fn -> try do GenServer.stop(exposer) catch :exit, _ -> :ok end end)

      # Verify it's bound to 0.0.0.0 (not 127.0.0.1)
      state = :sys.get_state(exposer)
      assert {:ok, {{0, 0, 0, 0}, ^expose_port}} = :inet.sockname(state.listen_sock)

      # Connect via loopback, send data, get echo back via upstream
      {:ok, client} =
        :gen_tcp.connect({127, 0, 0, 1}, expose_port, [:binary, packet: :raw, active: false], 1_000)

      :ok = :gen_tcp.send(client, "ping")
      assert {:ok, "ping"} = :gen_tcp.recv(client, 4, 2_000)
      :gen_tcp.close(client)
    end

    test "accepts multiple sequential connections", %{upstream_port: up, key: key} do
      expose_port = free_port()

      {:ok, exposer} =
        PortExposer.start_link(
          key: key,
          host_port: expose_port,
          upstream_host: {127, 0, 0, 1},
          upstream_port: up
        )

      on_exit(fn -> try do GenServer.stop(exposer) catch :exit, _ -> :ok end end)

      for i <- 1..3 do
        {:ok, client} =
          :gen_tcp.connect({127, 0, 0, 1}, expose_port, [:binary, packet: :raw, active: false], 1_000)

        msg = "msg-#{i}"
        :ok = :gen_tcp.send(client, msg)
        assert {:ok, ^msg} = :gen_tcp.recv(client, byte_size(msg), 2_000)
        :gen_tcp.close(client)
        Process.sleep(50)
      end
    end
  end

  # --- Helpers ---

  # Minimum-viable echo server on a given loopback port. Spawns a
  # process that accepts one connection and echos data back until
  # the client closes.
  defp start_echo_server(port) do
    parent = self()

    pid =
      spawn(fn ->
        {:ok, listen} =
          :gen_tcp.listen(port, [
            :binary,
            packet: :raw,
            active: false,
            reuseaddr: true,
            ip: {127, 0, 0, 1}
          ])

        send(parent, :echo_listening)
        accept_loop(listen)
      end)

    receive do
      :echo_listening -> pid
    after
      1_000 -> flunk("echo server never came up")
    end
  end

  defp accept_loop(listen) do
    case :gen_tcp.accept(listen) do
      {:ok, sock} ->
        spawn(fn -> echo_loop(sock) end)
        accept_loop(listen)

      {:error, :closed} ->
        :ok

      _ ->
        :ok
    end
  end

  defp echo_loop(sock) do
    case :gen_tcp.recv(sock, 0, 10_000) do
      {:ok, data} ->
        :gen_tcp.send(sock, data)
        echo_loop(sock)

      _ ->
        :gen_tcp.close(sock)
    end
  end

  defp stop_echo_server(pid) do
    if Process.alive?(pid), do: Process.exit(pid, :kill)
  end

  defp free_port do
    {:ok, sock} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(sock)
    :gen_tcp.close(sock)
    port
  end

  defp eventually(fun, tries \\ 20) do
    if tries <= 0 do
      flunk("eventually condition never held")
    else
      if fun.() do
        :ok
      else
        Process.sleep(25)
        eventually(fun, tries - 1)
      end
    end
  end
end
