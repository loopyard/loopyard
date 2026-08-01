defmodule Loopyard.Workspace.ServiceManagerTest do
  use ExUnit.Case

  alias Loopyard.Workspace.ServiceManager

  describe "naming" do
    test "service_container_name" do
      assert ServiceManager.service_container_name("abcd", "postgres") ==
               "#{Loopyard.Docker.prefix()}abcd-postgres-1"
    end

    test "service_volume_name" do
      assert ServiceManager.service_volume_name("abcd", "postgres") == "postgres-data-abcd"
    end
  end

  describe "service_status/1" do
    test "returns empty list for unknown workspace" do
      assert {:ok, []} =
               ServiceManager.service_status("/nonexistent/path/#{:rand.uniform(100_000)}")
    end
  end

  describe "subscribe/0" do
    test "subscribes to service updates" do
      assert :ok = ServiceManager.subscribe()
    end
  end
end
