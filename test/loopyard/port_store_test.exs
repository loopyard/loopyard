defmodule Loopyard.PortStoreTest do
  use ExUnit.Case, async: false

  alias Loopyard.PortStore

  setup do
    # Use LOOPYARD_HOME's ports.json directly — test_helper.exs sets
    # LOOPYARD_HOME to a local dir so tests don't touch ~/.loopyard.
    File.rm(PortStore.path())
    on_exit(fn -> File.rm(PortStore.path()) end)
    :ok
  end

  describe "load/0" do
    test "returns [] when the file doesn't exist" do
      refute File.exists?(PortStore.path())
      assert [] = PortStore.load()
    end

    test "returns [] on invalid JSON, without raising" do
      File.write!(PortStore.path(), "not json")
      assert [] = PortStore.load()
    end

    test "returns [] on unknown version, without raising" do
      File.write!(PortStore.path(), ~s({"version": 999, "entries": []}))
      assert [] = PortStore.load()
    end
  end

  describe "save/2 + load/0 round trip" do
    test "preserves every field" do
      entries = [
        %{
          workspace_id: "ws1",
          service: "dev",
          container_port: 3000,
          host_port: 4012,
          exposed: false,
          legacy: false,
          allocated_at: ~U[2026-04-15 10:00:00Z]
        },
        %{
          workspace_id: "ws2",
          service: "postgres",
          container_port: 5432,
          host_port: 32_771,
          exposed: true,
          legacy: true,
          allocated_at: ~U[2026-04-14 09:00:00Z]
        }
      ]

      :ok = PortStore.save(entries, 4000..9999)
      loaded = PortStore.load()

      assert length(loaded) == 2

      assert [e1, e2] = Enum.sort_by(loaded, & &1.workspace_id)

      assert e1.workspace_id == "ws1"
      assert e1.service == "dev"
      assert e1.container_port == 3000
      assert e1.host_port == 4012
      assert e1.exposed == false
      assert e1.legacy == false
      assert e1.allocated_at == ~U[2026-04-15 10:00:00Z]

      assert e2.exposed == true
      assert e2.legacy == true
      assert e2.host_port == 32_771
    end

    test "saves the configured port range as a JSON array" do
      :ok = PortStore.save([], 5000..7000)
      %{"port_range" => [5000, 7000]} = Jason.decode!(File.read!(PortStore.path()))
    end

    test "save followed by load on an empty list returns empty" do
      :ok = PortStore.save([], 4000..9999)
      assert [] = PortStore.load()
    end
  end

  describe "path/0" do
    test "lives under LOOPYARD_HOME" do
      assert String.ends_with?(PortStore.path(), "ports.json")
      assert String.contains?(PortStore.path(), Loopyard.Workspace.home_dir())
    end
  end
end
