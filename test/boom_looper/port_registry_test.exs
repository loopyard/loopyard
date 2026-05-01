defmodule BoomLooper.PortRegistryTest do
  @moduledoc """
  PortRegistry owns user-facing port allocation and proxy lifecycle.

  Contract:
    * `assign/3` is sticky per {workspace_id, service, container_port}
    * `assign/3` picks the lowest free port, verified against the OS
    * `set_docker_port/4` stores Docker's ephemeral port and starts proxy
    * `set_exposure/4` toggles proxy between 127.0.0.1 and 0.0.0.0
    * `release_workspace/1` stops proxies and frees entries
  """
  use ExUnit.Case, async: false

  alias BoomLooper.PortRegistry

  setup do
    BoomLooper.StateKeeper.ensure_tables!()
    :ets.delete_all_objects(:port_registry)

    base = free_port()
    range = base..(base + 9)
    :ok = PortRegistry.configure(port_range: range, persist: false)

    on_exit(fn ->
      # Stop any leftover proxies
      for {key, _} <- :ets.tab2list(:port_registry) do
        case BoomLooper.PortExposer.whereis(key) do
          nil -> :ok
          pid -> try do DynamicSupervisor.terminate_child(BoomLooper.PortExposerSupervisor, pid) catch _, _ -> :ok end
        end
      end

      :ets.delete_all_objects(:port_registry)
      PortRegistry.configure(port_range: 4000..9999, persist: false)
    end)

    %{range: range}
  end

  describe "assign/3" do
    test "returns {:ok, host_port} from the pool", %{range: range} do
      {:ok, port} = PortRegistry.assign("ws1", "dev", 3000)
      assert port == range.first
    end

    test "is sticky per triple" do
      {:ok, a} = PortRegistry.assign("ws1", "dev", 3000)
      {:ok, b} = PortRegistry.assign("ws1", "dev", 3000)
      assert a == b
    end

    test "distinct triples get distinct ports" do
      {:ok, a} = PortRegistry.assign("ws1", "dev", 3000)
      {:ok, b} = PortRegistry.assign("ws1", "postgres", 5432)
      {:ok, c} = PortRegistry.assign("ws2", "dev", 3000)
      assert length(Enum.uniq([a, b, c])) == 3
    end

    test "skips ports the OS has bound" do
      port = free_port()
      {:ok, holder} = :gen_tcp.listen(port, [:binary, ip: {0, 0, 0, 0}, active: false])
      :ok = PortRegistry.configure(port_range: port..(port + 5), persist: false)

      try do
        {:ok, assigned} = PortRegistry.assign("ws", "dev", 3000)
        refute assigned == port
      after
        :gen_tcp.close(holder)
      end
    end
  end

  describe "set_docker_port/4" do
    test "stores docker_port and starts proxy" do
      {:ok, host_port} = PortRegistry.assign("ws1", "dev", 3000)
      echo_port = start_echo_on_free_port()

      :ok = PortRegistry.set_docker_port("ws1", "dev", 3000, echo_port)

      # Proxy is running
      assert pid = BoomLooper.PortExposer.whereis({"ws1", "dev", 3000})
      assert Process.alive?(pid)

      # Entry has docker_port
      {:ok, entry} = PortRegistry.get("ws1", "dev", 3000)
      assert entry.docker_port == echo_port
      assert entry.host_port == host_port

      # Data flows through proxy
      {:ok, client} = :gen_tcp.connect({127, 0, 0, 1}, host_port, [:binary, active: false], 1_000)
      :gen_tcp.send(client, "ping")
      assert {:ok, "ping"} = :gen_tcp.recv(client, 4, 2_000)
      :gen_tcp.close(client)
    end

    test "returns :not_registered for unknown entries" do
      assert {:error, :not_registered} = PortRegistry.set_docker_port("nope", "dev", 3000, 12345)
    end

    test "updates proxy when docker_port changes (container restart)" do
      {:ok, host_port} = PortRegistry.assign("ws1", "dev", 3000)
      echo1 = start_echo_on_free_port()
      echo2 = start_echo_on_free_port()

      :ok = PortRegistry.set_docker_port("ws1", "dev", 3000, echo1)

      {:ok, c1} = :gen_tcp.connect({127, 0, 0, 1}, host_port, [:binary, active: false], 1_000)
      :gen_tcp.send(c1, "v1")
      assert {:ok, "v1"} = :gen_tcp.recv(c1, 2, 2_000)
      :gen_tcp.close(c1)

      # Docker restarts → new ephemeral port
      :ok = PortRegistry.set_docker_port("ws1", "dev", 3000, echo2)

      {:ok, c2} = :gen_tcp.connect({127, 0, 0, 1}, host_port, [:binary, active: false], 1_000)
      :gen_tcp.send(c2, "v2")
      assert {:ok, "v2"} = :gen_tcp.recv(c2, 2, 2_000)
      :gen_tcp.close(c2)
    end
  end

  describe "set_exposure/4" do
    test "true restarts proxy on 0.0.0.0" do
      {:ok, _} = PortRegistry.assign("ws1", "dev", 3000)
      echo_port = start_echo_on_free_port()
      :ok = PortRegistry.set_docker_port("ws1", "dev", 3000, echo_port)

      :ok = PortRegistry.set_exposure("ws1", "dev", 3000, true)

      state = :sys.get_state(BoomLooper.PortExposer.whereis({"ws1", "dev", 3000}))
      assert state.bind_ip == {0, 0, 0, 0}

      {:ok, entry} = PortRegistry.get("ws1", "dev", 3000)
      assert entry.exposed == true
    end

    test "false restarts proxy on 127.0.0.1" do
      {:ok, _} = PortRegistry.assign("ws1", "dev", 3000)
      echo_port = start_echo_on_free_port()
      :ok = PortRegistry.set_docker_port("ws1", "dev", 3000, echo_port)
      :ok = PortRegistry.set_exposure("ws1", "dev", 3000, true)
      :ok = PortRegistry.set_exposure("ws1", "dev", 3000, false)

      state = :sys.get_state(BoomLooper.PortExposer.whereis({"ws1", "dev", 3000}))
      assert state.bind_ip == {127, 0, 0, 1}

      {:ok, entry} = PortRegistry.get("ws1", "dev", 3000)
      assert entry.exposed == false
    end

    test "returns :no_docker_port when docker_port is nil" do
      {:ok, _} = PortRegistry.assign("ws1", "dev", 3000)
      assert {:error, :no_docker_port} = PortRegistry.set_exposure("ws1", "dev", 3000, true)
    end

    test "data flows after exposure toggle" do
      {:ok, host_port} = PortRegistry.assign("ws1", "dev", 3000)
      echo_port = start_echo_on_free_port()
      :ok = PortRegistry.set_docker_port("ws1", "dev", 3000, echo_port)

      # Private → exposed → private, data flows each time
      for exposed? <- [true, false, true] do
        :ok = PortRegistry.set_exposure("ws1", "dev", 3000, exposed?)

        {:ok, c} = :gen_tcp.connect({127, 0, 0, 1}, host_port, [:binary, active: false], 1_000)
        :gen_tcp.send(c, "ok")
        assert {:ok, "ok"} = :gen_tcp.recv(c, 2, 2_000)
        :gen_tcp.close(c)
      end
    end
  end

  describe "release_workspace/1" do
    test "stops proxy and removes entries" do
      {:ok, _} = PortRegistry.assign("ws1", "dev", 3000)
      echo_port = start_echo_on_free_port()
      :ok = PortRegistry.set_docker_port("ws1", "dev", 3000, echo_port)
      pid = BoomLooper.PortExposer.whereis({"ws1", "dev", 3000})

      :ok = PortRegistry.release_workspace("ws1")
      Process.sleep(50)

      refute Process.alive?(pid)
      assert [] = PortRegistry.list_for_workspace("ws1")
    end

    test "frees ports for reuse", %{range: range} do
      {:ok, first} = PortRegistry.assign("ws1", "dev", 3000)
      assert first == range.first

      :ok = PortRegistry.release_workspace("ws1")
      {:ok, second} = PortRegistry.assign("ws2", "dev", 3000)
      assert second == range.first
    end
  end

  describe "restore preserves exposure" do
    test "restore then assign keeps exposed: true" do
      # Simulate boot: restore loads an exposed port, then project
      # restore calls assign for the same triple.
      {:ok, port} = PortRegistry.assign("ws1", "dev", 3000)
      echo = start_echo_on_free_port()
      :ok = PortRegistry.set_docker_port("ws1", "dev", 3000, echo)
      :ok = PortRegistry.set_exposure("ws1", "dev", 3000, true)

      {:ok, entry_before} = PortRegistry.get("ws1", "dev", 3000)
      assert entry_before.exposed == true

      # Simulate server restart: clear ETS, restore from persistence,
      # then assign again (what ProjectRegistry.restore does)
      :ets.delete_all_objects(:port_registry)

      # Manual restore — insert the entry as if PortStore loaded it
      key = {"ws1", "dev", 3000}
      :ets.insert(:port_registry, {key, %{entry_before | docker_port: nil}})

      # Now assign again (what Compose.emit_port does during project restore)
      {:ok, same_port} = PortRegistry.assign("ws1", "dev", 3000)
      assert same_port == port

      # Exposure MUST be preserved
      {:ok, entry_after} = PortRegistry.get("ws1", "dev", 3000)
      assert entry_after.exposed == true, "assign clobbered exposed flag"
    end

    test "assign on empty table creates exposed: false" do
      {:ok, _} = PortRegistry.assign("ws1", "dev", 3000)
      {:ok, entry} = PortRegistry.get("ws1", "dev", 3000)
      assert entry.exposed == false
    end

    test "assign before restore loses exposure (the bug)" do
      # This documents the bug that the restore-order fix prevents.
      # If assign runs BEFORE restore, a fresh entry is created with
      # exposed: false, and the old exposed: true entry is lost.
      {:ok, port} = PortRegistry.assign("ws1", "dev", 3000)
      echo = start_echo_on_free_port()
      :ok = PortRegistry.set_docker_port("ws1", "dev", 3000, echo)
      :ok = PortRegistry.set_exposure("ws1", "dev", 3000, true)

      {:ok, entry_before} = PortRegistry.get("ws1", "dev", 3000)
      assert entry_before.exposed == true

      # Clear ETS (simulating BEAM restart)
      :ets.delete_all_objects(:port_registry)

      # Assign FIRST (the wrong order — this is what used to happen)
      {:ok, _} = PortRegistry.assign("ws1", "dev", 3000)

      # The new entry has exposed: false
      {:ok, fresh_entry} = PortRegistry.get("ws1", "dev", 3000)
      assert fresh_entry.exposed == false, "fresh entry should default to unexposed"
    end

    test "port number is sticky across assign calls" do
      {:ok, port1} = PortRegistry.assign("ws1", "dev", 3000)
      {:ok, port2} = PortRegistry.assign("ws1", "dev", 3000)
      {:ok, port3} = PortRegistry.assign("ws1", "dev", 3000)
      assert port1 == port2
      assert port2 == port3
    end

    test "set_docker_port preserves exposed flag" do
      {:ok, _} = PortRegistry.assign("ws1", "dev", 3000)
      echo1 = start_echo_on_free_port()
      :ok = PortRegistry.set_docker_port("ws1", "dev", 3000, echo1)
      :ok = PortRegistry.set_exposure("ws1", "dev", 3000, true)

      # Container restart → new docker port
      echo2 = start_echo_on_free_port()
      :ok = PortRegistry.set_docker_port("ws1", "dev", 3000, echo2)

      {:ok, entry} = PortRegistry.get("ws1", "dev", 3000)
      assert entry.exposed == true, "docker port change clobbered exposed"
      assert entry.docker_port == echo2
    end
  end

  # --- Helpers ---

  defp free_port do
    {:ok, sock} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(sock)
    :gen_tcp.close(sock)
    port
  end

  defp start_echo_on_free_port do
    port = free_port()
    parent = self()

    spawn(fn ->
      {:ok, listen} = :gen_tcp.listen(port, [:binary, packet: :raw, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])
      send(parent, {:echo_up, port})
      accept_loop(listen)
    end)

    receive do
      {:echo_up, ^port} -> port
    after
      1_000 -> flunk("echo server didn't start")
    end
  end

  defp accept_loop(listen) do
    case :gen_tcp.accept(listen) do
      {:ok, sock} -> spawn(fn -> echo_loop(sock) end); accept_loop(listen)
      _ -> :ok
    end
  end

  defp echo_loop(sock) do
    case :gen_tcp.recv(sock, 0, 10_000) do
      {:ok, data} -> :gen_tcp.send(sock, data); echo_loop(sock)
      _ -> :gen_tcp.close(sock)
    end
  end
end
