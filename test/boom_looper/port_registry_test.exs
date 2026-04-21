defmodule BoomLooper.PortRegistryTest do
  @moduledoc """
  The registry owns host-port allocation. The contract is:

    * `assign/3` is sticky per `{workspace_id, service, container_port}`.
      Same call returns the same host port every time.
    * `assign/3` picks the lowest unused port in the configured range.
    * `release_workspace/1` frees every entry for that workspace and
      returns those ports to the pool.
    * Pool exhaustion returns `{:error, :port_pool_exhausted}`.
    * Legacy entries (migrated from the old sticky-port map) are
      respected — their host_port stays in use even if it's outside
      the current configured range.

  Tests here never touch the real on-disk store. `setup` starts the
  registry with a per-test in-memory config and a NullStore so assign
  and release are pure ETS operations. The on-disk round trip is
  covered in `port_store_test.exs`.
  """
  use ExUnit.Case, async: false

  alias BoomLooper.PortRegistry

  setup context do
    BoomLooper.StateKeeper.ensure_tables!()
    :ets.delete_all_objects(:port_registry)

    # Build a range anchored at a provably-free port. Since v2, the
    # registry trial-binds candidates; a fixed range like 4000..4009
    # would collide with whatever the dev environment happens to
    # occupy and flake randomly.
    #
    # Tests that care about exhaustion override with @tag range_size: 2.
    range_size = Map.get(context, :range_size, 10)
    base = free_port()
    range = base..(base + range_size - 1)

    :ok = PortRegistry.configure(port_range: range, persist: false)

    on_exit(fn ->
      :ets.delete_all_objects(:port_registry)
      PortRegistry.configure(port_range: 4000..9999, persist: false)
    end)

    %{range: range}
  end

  defp free_port do
    {:ok, sock} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(sock)
    :gen_tcp.close(sock)
    port
  end

  defp wait_until(fun, tries \\ 40) do
    cond do
      tries <= 0 -> :timeout
      fun.() -> :ok
      true ->
        Process.sleep(25)
        wait_until(fun, tries - 1)
    end
  end

  describe "assign/3" do
    test "returns {:ok, host_port} with the lowest unused port", %{range: range} do
      assert {:ok, host_port} = PortRegistry.assign("ws1", "dev", 3000)
      assert host_port == range.first
    end

    test "is sticky per {workspace_id, service, container_port}" do
      {:ok, first} = PortRegistry.assign("ws1", "dev", 3000)
      {:ok, second} = PortRegistry.assign("ws1", "dev", 3000)
      assert first == second
    end

    test "distinct triples get distinct ports" do
      {:ok, a} = PortRegistry.assign("ws1", "dev", 3000)
      {:ok, b} = PortRegistry.assign("ws1", "postgres", 5432)
      {:ok, c} = PortRegistry.assign("ws2", "dev", 3000)

      assert Enum.uniq([a, b, c]) |> length() == 3
    end

    test "fills the pool from the bottom up", %{range: range} do
      hosts =
        for i <- 1..5 do
          {:ok, host} = PortRegistry.assign("ws#{i}", "dev", 3000)
          host
        end

      assert hosts == Enum.take(range, 5)
    end

    @tag range_size: 2
    test "returns :port_pool_exhausted when every port is taken" do
      {:ok, _} = PortRegistry.assign("ws1", "dev", 3000)
      {:ok, _} = PortRegistry.assign("ws2", "dev", 3000)
      assert {:error, :port_pool_exhausted} = PortRegistry.assign("ws3", "dev", 3000)
    end

    test "skips ports the OS already has bound" do
      # Hold a real OS-level listener on an in-range port. Registry must
      # see it as taken even though it's not in its own ETS table, and
      # hand out the NEXT port instead.
      port = free_port()
      {:ok, holder} = :gen_tcp.listen(port, [:binary, ip: {0, 0, 0, 0}, active: false])

      :ok = PortRegistry.configure(port_range: port..(port + 5), persist: false)

      try do
        {:ok, assigned} = PortRegistry.assign("skip-os", "dev", 3000)
        refute assigned == port
        assert assigned > port and assigned <= port + 5
      after
        :gen_tcp.close(holder)
      end
    end
  end

  describe "get/3 and list_for_workspace/1" do
    test "get/3 returns :none for unknown keys" do
      assert :none = PortRegistry.get("nope", "dev", 3000)
    end

    test "get/3 returns the entry after assign" do
      {:ok, host_port} = PortRegistry.assign("ws1", "dev", 3000)
      assert {:ok, %{host_port: ^host_port, workspace_id: "ws1"}} = PortRegistry.get("ws1", "dev", 3000)
    end

    test "list_for_workspace/1 returns all entries for that workspace" do
      {:ok, _} = PortRegistry.assign("ws1", "dev", 3000)
      {:ok, _} = PortRegistry.assign("ws1", "postgres", 5432)
      {:ok, _} = PortRegistry.assign("ws2", "dev", 3000)

      entries = PortRegistry.list_for_workspace("ws1")
      assert length(entries) == 2
      assert Enum.all?(entries, &(&1.workspace_id == "ws1"))
    end
  end

  describe "release_workspace/1" do
    test "removes every entry for that workspace" do
      {:ok, _} = PortRegistry.assign("ws1", "dev", 3000)
      {:ok, _} = PortRegistry.assign("ws1", "postgres", 5432)
      {:ok, _} = PortRegistry.assign("ws2", "dev", 3000)

      :ok = PortRegistry.release_workspace("ws1")

      assert [] = PortRegistry.list_for_workspace("ws1")
      # ws2 untouched
      assert [_one] = PortRegistry.list_for_workspace("ws2")
    end

    test "frees the ports for reuse", %{range: range} do
      {:ok, first} = PortRegistry.assign("ws1", "dev", 3000)
      assert first == range.first

      :ok = PortRegistry.release_workspace("ws1")
      {:ok, second} = PortRegistry.assign("ws2", "dev", 3000)

      # Reuses the lowest now-free port, which is the one we just released
      assert second == range.first
    end

    test "is a no-op for unknown workspaces" do
      assert :ok = PortRegistry.release_workspace("never-assigned")
    end
  end

  describe "seed/4 — migration helper" do
    test "inserts a legacy entry marked legacy: true" do
      :ok = PortRegistry.seed("ws1", "dev", 3000, 32771)

      assert {:ok, entry} = PortRegistry.get("ws1", "dev", 3000)
      assert entry.host_port == 32771
      assert entry.legacy == true
    end

    test "legacy ports count as in-use for future assigns", %{range: range} do
      # 32771 is outside our configured range but the allocator must
      # still know it's taken so nothing can double-assign it even if
      # the range grows later.
      :ok = PortRegistry.seed("ws1", "dev", 3000, 32771)

      # New assigns still come from the configured range, unaffected
      {:ok, host} = PortRegistry.assign("ws2", "dev", 3000)
      assert host >= range.first and host <= range.last
    end

    test "calling seed twice with the same key overwrites (idempotent)" do
      :ok = PortRegistry.seed("ws1", "dev", 3000, 32771)
      :ok = PortRegistry.seed("ws1", "dev", 3000, 32771)

      assert [_one] = PortRegistry.list_for_workspace("ws1")
    end
  end

  describe "set_exposure/4" do
    test "true starts a PortExposer on the registered host_port" do
      port = free_port()
      :ok = PortRegistry.seed("ws-e", "dev", 3000, port)

      assert :ok = PortRegistry.set_exposure("ws-e", "dev", 3000, true)

      assert pid = BoomLooper.PortExposer.whereis({"ws-e", "dev", 3000})
      assert is_pid(pid) and Process.alive?(pid)

      assert {:ok, %{exposed: true}} = PortRegistry.get("ws-e", "dev", 3000)

      :ok = PortRegistry.set_exposure("ws-e", "dev", 3000, false)
    end

    test "false stops the running exposer" do
      port = free_port()
      :ok = PortRegistry.seed("ws-e", "dev", 3000, port)

      :ok = PortRegistry.set_exposure("ws-e", "dev", 3000, true)
      pid = BoomLooper.PortExposer.whereis({"ws-e", "dev", 3000})

      :ok = PortRegistry.set_exposure("ws-e", "dev", 3000, false)

      # Eventually consistent — DynamicSupervisor.terminate_child returns
      # before Registry unregistration completes.
      :ok = wait_until(fn -> not Process.alive?(pid) end)
      assert nil == BoomLooper.PortExposer.whereis({"ws-e", "dev", 3000})
      assert {:ok, %{exposed: false}} = PortRegistry.get("ws-e", "dev", 3000)
    end

    test "returns :not_registered for unknown keys" do
      assert {:error, :not_registered} =
               PortRegistry.set_exposure("nope", "dev", 3000, true)
    end

    test "is a no-op when the desired state already matches" do
      port = free_port()
      :ok = PortRegistry.seed("ws-e", "dev", 3000, port)

      :ok = PortRegistry.set_exposure("ws-e", "dev", 3000, true)
      pid = BoomLooper.PortExposer.whereis({"ws-e", "dev", 3000})

      # Second call should not churn the listener.
      :ok = PortRegistry.set_exposure("ws-e", "dev", 3000, true)
      assert pid == BoomLooper.PortExposer.whereis({"ws-e", "dev", 3000})

      :ok = PortRegistry.set_exposure("ws-e", "dev", 3000, false)
    end

    test "release_workspace/1 stops any running exposer for the workspace" do
      port = free_port()
      :ok = PortRegistry.seed("ws-rel", "dev", 3000, port)
      :ok = PortRegistry.set_exposure("ws-rel", "dev", 3000, true)
      pid = BoomLooper.PortExposer.whereis({"ws-rel", "dev", 3000})

      :ok = PortRegistry.release_workspace("ws-rel")

      :ok = wait_until(fn -> not Process.alive?(pid) end)
      assert nil == BoomLooper.PortExposer.whereis({"ws-rel", "dev", 3000})
    end
  end

  describe "retry_exposure/3 (agent-sanity #7)" do
    test "happy path — retries on a now-free port succeeds", %{range: range} do
      port = free_port()
      :ok = PortRegistry.seed("ws-retry", "dev", 3000, port)

      # Seeded entry has exposed: false. Flip to true via set_exposure
      # so we're in the state restore_entries would see.
      :ok = PortRegistry.set_exposure("ws-retry", "dev", 3000, true)
      :ok = PortRegistry.set_exposure("ws-retry", "dev", 3000, false)

      # Directly calling retry_exposure on an entry with no active
      # listener should succeed. Range is scoped so the free_port() is
      # still legitimate.
      _ = range
      assert :ok = PortRegistry.retry_exposure("ws-retry", "dev", 3000)

      :ok = PortRegistry.set_exposure("ws-retry", "dev", 3000, false)
    end

    # The "host_port collision → reassign" path was written when
    # start_exposer bound entry.host_port directly on 0.0.0.0. Since
    # then, start_exposer allocates a SEPARATE OS-assigned expose_port
    # and forwards to the upstream host_port — expose_port collisions
    # are effectively impossible because :gen_tcp.listen(0) picks a
    # free port each time. The reassign code still exists as a safety
    # net for :port_pool_exhausted but the EADDRINUSE retry scenario
    # is no longer reachable via the public API. Test removed; the
    # retry_exposure/3 happy path + not-found cases still verify the
    # API contract.

    test "not-found key returns :not_found" do
      assert {:error, :not_found} = PortRegistry.retry_exposure("nope", "dev", 3000)
    end
  end

  describe "concurrent assigns" do
    test "two concurrent assigns for the same triple return the same port" do
      me = self()

      Enum.each(1..20, fn i ->
        spawn(fn ->
          result = PortRegistry.assign("ws-race", "dev", 3000)
          send(me, {i, result})
        end)
      end)

      results =
        for _ <- 1..20 do
          receive do
            {_i, result} -> result
          after
            1_000 -> flunk("assign timed out")
          end
        end

      ports = Enum.map(results, fn {:ok, p} -> p end)
      assert length(Enum.uniq(ports)) == 1, "sticky assign must return the same port under concurrency"
    end

    test "concurrent assigns for distinct triples never collide" do
      me = self()

      Enum.each(1..5, fn i ->
        spawn(fn ->
          result = PortRegistry.assign("ws-race-#{i}", "dev", 3000)
          send(me, {i, result})
        end)
      end)

      results =
        for _ <- 1..5 do
          receive do
            {_i, result} -> result
          after
            1_000 -> flunk("assign timed out")
          end
        end

      ports = Enum.map(results, fn {:ok, p} -> p end)
      assert length(Enum.uniq(ports)) == 5, "distinct triples under concurrency must get distinct ports"
    end
  end
end
