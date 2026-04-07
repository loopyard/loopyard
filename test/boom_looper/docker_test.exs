defmodule BoomLooper.DockerTest do
  use ExUnit.Case

  alias BoomLooper.Docker

  describe "container_running?/1" do
    test "returns false for non-existent container" do
      refute Docker.container_running?("nonexistent-container-#{:rand.uniform(100_000)}")
    end
  end

  describe "container_ports/1" do
    test "returns empty map for non-existent container" do
      assert Docker.container_ports("nonexistent-#{:rand.uniform(100_000)}") == %{}
    end
  end

  describe "port_open?/1" do
    test "returns false for unused port" do
      refute Docker.port_open?(59999)
    end
  end

  describe "list_containers/1" do
    @describetag :docker

    test "returns a list" do
      result = Docker.list_containers()
      assert is_list(result)
    end

    test "filters by prefix" do
      assert is_list(Docker.list_containers(prefix: "bl-"))
    end
  end

  describe "docker/2" do
    @describetag :docker

    test "runs a docker command" do
      assert {:ok, output} = Docker.docker(["version", "--format", "{{.Client.Version}}"])
      assert output != ""
    end

    test "returns error for invalid command" do
      assert {:error, _} = Docker.docker(["nonexistent-command-xyz"])
    end
  end
end
