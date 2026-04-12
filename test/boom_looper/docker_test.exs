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

  describe "telemetry" do
    @describetag :docker

    test "docker/2 emits telemetry span events" do
      ref = make_ref()
      handler_id = "test-telemetry-#{inspect(ref)}"

      :telemetry.attach(handler_id, [:boom_looper, :docker, :command, :stop],
        fn _name, measurements, metadata, {pid, test_ref} ->
          send(pid, {:telemetry_stop, test_ref, measurements, metadata})
        end, {self(), ref})

      # This may fail if docker isn't installed, but the telemetry fires either way
      Docker.docker(["version"])

      assert_receive {:telemetry_stop, ^ref, %{duration: duration}, %{args: ["version"]}}, 5_000
      assert is_integer(duration)

      :telemetry.detach(handler_id)
    end
  end

  describe "stream/3" do
    test "returns error when docker not in PATH" do
      # We can't easily test the streaming loop without docker, but we can
      # verify the open_port error path returns cleanly.
      original_path = System.get_env("PATH")

      try do
        System.put_env("PATH", "/nonexistent-path-for-test")
        assert {:error, _} = Docker.stream(["version"], fn _ -> :ok end)
      after
        if original_path, do: System.put_env("PATH", original_path)
      end
    end

    @tag :docker
    test "invokes callback with streaming chunks" do
      ref = make_ref()
      parent = self()

      callback = fn data ->
        send(parent, {ref, :chunk, data})
      end

      assert {:ok, output} = Docker.stream(["version", "--format", "{{.Client.Version}}"], callback)
      assert output != ""

      # At least one chunk should have arrived
      assert_received {^ref, :chunk, _}
    end
  end
end
