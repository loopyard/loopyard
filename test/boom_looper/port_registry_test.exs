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
          nil ->
            :ok

          pid ->
            try do
              DynamicSupervisor.terminate_child(BoomLooper.PortExposerSupervisor, pid)
            catch
              _, _ -> :ok
            end
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

  describe "supervisor DOWN preserves binding (the page-refresh regression)" do
    # The Resources.Janitor monitors the WorkspaceGroup supervisor pid.
    # When that pid goes DOWN — supervisor restart, :one_for_all
    # cascade, rebuild_saga teardown — the janitor invokes the
    # release_fn registered for :port_binding.
    #
    # Bug history: release_binding/3 used to ALSO :ets.delete the
    # registry row, conflating "stop the proxy" with "forget the user
    # exposed this port". Page refresh would silently un-expose
    # whenever ServiceManager had flapped, because mount sends
    # :start_workspace and WorkspaceSupervisor.start_workspace
    # rebuilds an unhealthy group. These tests pin the corrected
    # behaviour: supervisor DOWN stops the proxy but the binding
    # record (host_port + exposed flag) survives.
    test "DOWN preserves exposed: true and host_port" do
      ws = "ws-down-1"
      sup = spawn_fake_supervisor(ws)

      {:ok, host_port} = PortRegistry.assign(ws, "dev", 3000)
      echo = start_echo_on_free_port()
      :ok = PortRegistry.set_docker_port(ws, "dev", 3000, echo)
      :ok = PortRegistry.set_exposure(ws, "dev", 3000, true)

      kill_and_wait(sup)

      {:ok, entry} = PortRegistry.get(ws, "dev", 3000)
      assert entry.exposed == true, "exposure was lost on supervisor DOWN"
      assert entry.host_port == host_port, "host_port changed across supervisor DOWN"
    end

    test "DOWN preserves exposed: false bindings too" do
      # The bug only ever lost exposed: true ports (because exposed:
      # false was the default for fresh entries), but the invariant
      # is "binding records are durable across supervisor lifetime"
      # — applies regardless of the exposed flag.
      ws = "ws-down-2"
      sup = spawn_fake_supervisor(ws)

      {:ok, host_port} = PortRegistry.assign(ws, "dev", 3000)
      echo = start_echo_on_free_port()
      :ok = PortRegistry.set_docker_port(ws, "dev", 3000, echo)

      kill_and_wait(sup)

      {:ok, entry} = PortRegistry.get(ws, "dev", 3000)
      assert entry.exposed == false
      assert entry.host_port == host_port
    end

    test "DOWN stops the proxy" do
      ws = "ws-down-3"
      sup = spawn_fake_supervisor(ws)

      {:ok, _} = PortRegistry.assign(ws, "dev", 3000)
      echo = start_echo_on_free_port()
      :ok = PortRegistry.set_docker_port(ws, "dev", 3000, echo)
      :ok = PortRegistry.set_exposure(ws, "dev", 3000, true)

      proxy_pid = BoomLooper.PortExposer.whereis({ws, "dev", 3000})
      assert is_pid(proxy_pid) and Process.alive?(proxy_pid)

      kill_and_wait(sup)

      # The proxy must be torn down — the docker_port may be stale
      # by the time the supervisor comes back.
      refute BoomLooper.PortExposer.whereis({ws, "dev", 3000}),
             "proxy lingered after supervisor DOWN"
    end

    test "host_port is sticky across DOWN + re-assign" do
      ws = "ws-down-4"
      sup = spawn_fake_supervisor(ws)

      {:ok, original} = PortRegistry.assign(ws, "dev", 3000)
      echo = start_echo_on_free_port()
      :ok = PortRegistry.set_docker_port(ws, "dev", 3000, echo)
      :ok = PortRegistry.set_exposure(ws, "dev", 3000, true)

      kill_and_wait(sup)

      # Simulate the new WorkspaceGroup booting and compose calling
      # assign for the same triple.
      _new_sup = spawn_fake_supervisor(ws)
      {:ok, after_port} = PortRegistry.assign(ws, "dev", 3000)
      assert after_port == original, "host_port was reallocated across DOWN"

      {:ok, entry} = PortRegistry.get(ws, "dev", 3000)
      assert entry.exposed == true, "exposure was lost across DOWN+reassign"
    end

    test "proxy comes back on 0.0.0.0 after DOWN + new docker_port (full round trip)" do
      ws = "ws-down-5"
      sup = spawn_fake_supervisor(ws)

      {:ok, host_port} = PortRegistry.assign(ws, "dev", 3000)
      echo1 = start_echo_on_free_port()
      :ok = PortRegistry.set_docker_port(ws, "dev", 3000, echo1)
      :ok = PortRegistry.set_exposure(ws, "dev", 3000, true)

      kill_and_wait(sup)

      # New supervisor + new ephemeral docker port (container restart
      # during outage is the realistic scenario).
      _new_sup = spawn_fake_supervisor(ws)
      {:ok, ^host_port} = PortRegistry.assign(ws, "dev", 3000)
      echo2 = start_echo_on_free_port()
      :ok = PortRegistry.set_docker_port(ws, "dev", 3000, echo2)

      proxy = BoomLooper.PortExposer.whereis({ws, "dev", 3000})
      assert is_pid(proxy), "proxy did not come back after DOWN+reassign"

      state = :sys.get_state(proxy)

      assert state.bind_ip == {0, 0, 0, 0},
             "proxy came back on private bind despite preserved exposed: true"

      # Real data flow check — not just internal state.
      {:ok, c} = :gen_tcp.connect({127, 0, 0, 1}, host_port, [:binary, active: false], 1_000)
      :gen_tcp.send(c, "rt")
      assert {:ok, "rt"} = :gen_tcp.recv(c, 2, 2_000)
      :gen_tcp.close(c)
    end

    test "release_workspace/1 still wipes everything (destructive path unchanged)" do
      # Regression guard: the fix narrows release_binding to "stop
      # proxy only", but the explicit destructor in
      # release_workspace/1 must continue to delete entries.
      ws = "ws-down-6"
      sup = spawn_fake_supervisor(ws)

      {:ok, _} = PortRegistry.assign(ws, "dev", 3000)
      echo = start_echo_on_free_port()
      :ok = PortRegistry.set_docker_port(ws, "dev", 3000, echo)
      :ok = PortRegistry.set_exposure(ws, "dev", 3000, true)

      :ok = PortRegistry.release_workspace(ws)
      Process.sleep(50)

      assert :none = PortRegistry.get(ws, "dev", 3000)
      assert [] = PortRegistry.list_for_workspace(ws)
      refute BoomLooper.PortExposer.whereis({ws, "dev", 3000})

      # Quiet the unused-binding warning; the supervisor reference
      # is held only so the GC doesn't collect it mid-test.
      _ = sup
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
      {:ok, listen} =
        :gen_tcp.listen(port, [
          :binary,
          packet: :raw,
          active: false,
          reuseaddr: true,
          ip: {127, 0, 0, 1}
        ])

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
      {:ok, sock} ->
        spawn(fn -> echo_loop(sock) end)
        accept_loop(listen)

      _ ->
        :ok
    end
  end

  # Stand-in for the WorkspaceGroup supervisor pid: a process that
  # registers itself in `BoomLooper.WorkspaceRegistry` keyed by the
  # workspace_id, so `track_binding/3` finds an owner. Returns the
  # pid; the caller kills it via `kill_and_wait/1` to drive the
  # janitor's DOWN handler synchronously enough for assertions.
  defp spawn_fake_supervisor(ws_id) do
    parent = self()

    pid =
      spawn(fn ->
        case Registry.register(BoomLooper.WorkspaceRegistry, ws_id, nil) do
          {:ok, _} -> :ok
          {:error, {:already_registered, _}} -> :ok
        end

        send(parent, :registered)

        receive do
          :stop -> :ok
        after
          5_000 -> :ok
        end
      end)

    receive do
      :registered -> :ok
    after
      1_000 -> flunk("fake supervisor did not register within 1s")
    end

    pid
  end

  # Kill the fake supervisor and block until the janitor has
  # processed the DOWN. Without the second wait the next assertion
  # races the release_fn — which would intermittently pass even on
  # broken code.
  defp kill_and_wait(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      1_000 -> flunk("fake supervisor refused to die")
    end

    # Drain the janitor's mailbox: :sys.get_state/1 is a synchronous
    # call that gets queued AFTER the {:DOWN, ...} message we just
    # produced. By the time it returns, the janitor has finished
    # handling the DOWN — including running release_binding for
    # every port owned by `pid`. Without this, the next assertion
    # would race the release_fn.
    _ = :sys.get_state(BoomLooper.Resources.Janitor)
    :ok
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
end
