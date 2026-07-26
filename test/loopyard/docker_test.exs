defmodule Loopyard.DockerTest do
  use ExUnit.Case

  alias Loopyard.Docker

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
      assert is_list(Docker.list_containers(prefix: "loopyard-"))
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

      :telemetry.attach(
        handler_id,
        [:loopyard, :docker, :command, :stop],
        fn _name, measurements, metadata, {pid, test_ref} ->
          send(pid, {:telemetry_stop, test_ref, measurements, metadata})
        end,
        {self(), ref}
      )

      # This may fail if docker isn't installed, but the telemetry fires either way
      Docker.docker(["version"])

      assert_receive {:telemetry_stop, ^ref, %{duration: duration}, %{args: ["version"]}}, 5_000
      assert is_integer(duration)

      :telemetry.detach(handler_id)
    end
  end

  describe "scrub_secrets/1 (telemetry credential redaction — pure)" do
    test "redacts a token in a URL but keeps the URL shape" do
      cmd = "git push https://ghp_SECRETTOKEN@github.com/acme/x HEAD:main"
      [scrubbed] = Docker.scrub_secrets([cmd])
      refute scrubbed =~ "ghp_SECRETTOKEN", "the token must never reach telemetry"
      assert scrubbed =~ "//***@github.com/acme/x", "credentials redacted, path kept"
    end

    test "redacts user:pass userinfo too" do
      assert Docker.scrub_secrets(["clone https://u:p@host/r"]) == ["clone https://***@host/r"]
    end

    test "leaves token-free args untouched (the common case)" do
      assert Docker.scrub_secrets(["version"]) == ["version"]
      assert Docker.scrub_secrets(["run", "--rm", "alpine/git"]) == ["run", "--rm", "alpine/git"]
      # a bare github URL with no credentials is unchanged
      assert Docker.scrub_secrets(["push https://github.com/a/b"]) == [
               "push https://github.com/a/b"
             ]
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

      assert {:ok, output} =
               Docker.stream(["version", "--format", "{{.Client.Version}}"], callback)

      assert output != ""

      # At least one chunk should have arrived
      assert_received {^ref, :chunk, _}
    end
  end

  describe "transient_error?/1" do
    test "recognizes daemon-connection failures as transient" do
      for msg <- [
            "Cannot connect to the Docker daemon at unix:///var/run/docker.sock",
            "error during connect: Post http://docker/v1.41/containers/create",
            "dial unix /var/run/docker.sock: connect: connection refused",
            "connection refused",
            "net/http: request canceled while waiting for connection",
            "read unix @->/var/run/docker.sock: i/o timeout",
            "EOF"
          ] do
        assert Docker.transient_error?(msg),
               "expected #{inspect(msg)} to be treated as transient"
      end
    end

    test "treats a missing socket file as PERMANENT (fail-fast, not retry)" do
      # Colima/Docker Desktop not running — the socket file genuinely
      # doesn't exist on disk. Retrying 3x with backoff burns ~1.3s
      # per call for nothing; the socket isn't going to materialize.
      for msg <- [
            "dial unix /var/run/docker.sock: connect: no such file or directory",
            "dial unix /Users/me/.colima/default/docker.sock: connect: no such file or directory"
          ] do
        refute Docker.transient_error?(msg),
               "expected #{inspect(msg)} to fail fast (socket file missing)"
      end
    end

    test "does NOT retry domain errors that aren't going to fix themselves" do
      for msg <- [
            "Error: No such container: nope",
            "Error response from daemon: No such volume: ghost-vol",
            "Error response from daemon: conflict: unable to delete",
            "invalid reference format"
          ] do
        refute Docker.transient_error?(msg),
               "expected #{inspect(msg)} to NOT be treated as transient"
      end
    end

    test "non-binary input returns false" do
      refute Docker.transient_error?(nil)
      refute Docker.transient_error?(:atom)
      refute Docker.transient_error?(123)
    end
  end
end
