defmodule BoomLooper.Resources.PortRegistryIntegrationTest do
  @moduledoc """
  Integration test for Move #7b's PortRegistry migration: when the
  workspace supervisor pid dies, every port binding it owned releases
  automatically via the Resources janitor.

  Exercises the real `track_port_binding/3` path + janitor DOWN
  handler. Uses a synthetic pid registered as `WorkspaceGroup` for
  the test workspace id so we don't need to boot a full compose
  cluster.
  """
  use ExUnit.Case, async: false

  alias BoomLooper.{PortRegistry, Resources}

  setup do
    # Stay in-memory for the test; each test uses a unique workspace
    # id so parallel cleanup across the PortRegistry state doesn't
    # interfere.
    PortRegistry.configure(persist: false)
    :ets.delete_all_objects(:port_registry)
    :ets.delete_all_objects(:resource_registry)

    on_exit(fn ->
      :ets.delete_all_objects(:port_registry)
      :ets.delete_all_objects(:resource_registry)
    end)

    :ok
  end

  describe "port bindings tracked under workspace supervisor pid" do
    test "assign tracks the binding via Resources" do
      ws = "integration-ws-#{:rand.uniform(1_000_000)}"

      # Stand up a fake workspace group pid registered under the ws id
      # so PortRegistry.track_port_binding can find an owner.
      {owner, _ref} = spawn_workspace_group(ws)

      assert {:ok, _host_port} = PortRegistry.assign(ws, "web", 3000)

      # Resources knows about the binding.
      resources = Resources.list_for_owner(owner)
      assert Enum.any?(resources, &(&1.kind == :port_binding))

      stop_workspace_group(owner)
    end

    test "workspace supervisor DOWN auto-releases every port for that workspace" do
      ws = "autorelease-ws-#{:rand.uniform(1_000_000)}"
      {owner, ref} = spawn_workspace_group(ws)

      assert {:ok, _} = PortRegistry.assign(ws, "web", 3000)
      assert {:ok, _} = PortRegistry.assign(ws, "web", 3001)
      assert {:ok, _} = PortRegistry.assign(ws, "db", 5432)

      assert length(PortRegistry.list_for_workspace(ws)) == 3
      assert length(Resources.list_for_owner(owner)) == 3

      stop_workspace_group(owner)
      assert_receive {:DOWN, ^ref, :process, ^owner, _}, 500

      # Release stops proxies but preserves ETS entries (host_port +
      # exposed flag survive supervisor restarts). Resources are cleared.
      assert eventually(fn -> Resources.list_for_owner(owner) == [] end, 1_000)

      # Entries still exist (port assignment is durable)
      assert length(PortRegistry.list_for_workspace(ws)) == 3
    end

    test "explicit release_workspace/1 untracks — no double-release on later DOWN" do
      ws = "no-double-release-ws-#{:rand.uniform(1_000_000)}"
      {owner, ref} = spawn_workspace_group(ws)

      assert {:ok, _} = PortRegistry.assign(ws, "web", 3000)

      # Operator calls release_workspace explicitly (the Destructor path).
      assert :ok = PortRegistry.release_workspace(ws)
      assert PortRegistry.list_for_workspace(ws) == []
      assert Resources.list_for_owner(owner) == []

      # Now kill the workspace supervisor. The janitor should see no
      # tracked resources and do nothing (no crash, no error).
      stop_workspace_group(owner)
      assert_receive {:DOWN, ^ref, :process, ^owner, _}, 500

      # Still empty. No spurious re-insert.
      assert PortRegistry.list_for_workspace(ws) == []
    end
  end

  # ── Helpers ──

  # Register a plain pid in BoomLooper.WorkspaceRegistry under the
  # given workspace id so PortRegistry.track_port_binding sees it
  # as the owner. The pid idles on a receive loop so we can kill it
  # deterministically.
  defp spawn_workspace_group(ws) do
    parent = self()

    pid =
      spawn(fn ->
        {:ok, _} = Registry.register(BoomLooper.WorkspaceRegistry, ws, nil)
        send(parent, :registered)

        receive do
          :stop -> :ok
        end
      end)

    # Wait for the registration to land before returning — assigns
    # race against it otherwise.
    receive do
      :registered -> :ok
    after
      500 -> flunk("workspace group pid failed to register")
    end

    ref = Process.monitor(pid)
    {pid, ref}
  end

  defp stop_workspace_group(pid) do
    if Process.alive?(pid), do: send(pid, :stop)
    :ok
  end

  # Poll-based wait helper for async release pipelines. The janitor
  # uses Task.Supervisor.start_child so release is eventually-
  # consistent; 1s is plenty on a local machine.
  defp eventually(check, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(check, deadline)
  end

  defp do_eventually(check, deadline) do
    if check.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        Process.sleep(20)
        do_eventually(check, deadline)
      end
    end
  end
end
