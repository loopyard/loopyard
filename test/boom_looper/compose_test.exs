defmodule BoomLooper.ComposeTest do
  use ExUnit.Case

  alias BoomLooper.{Compose, Workspace}

  describe "generate/3" do
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "boom-looper-compose-test-#{:rand.uniform(100_000)}")
      File.mkdir_p!(Path.join(tmp_dir, ".boomlooper/workspace"))
      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      %{tmp_dir: tmp_dir}
    end

    test "generates compose with workspace, dev, and stock services", %{tmp_dir: tmp_dir} do
      ws = %Workspace{
        name: "test-project",
        dockerfile: "FROM ruby:3.4\nWORKDIR /workspace",
        processes: [%{name: "dev", command: "bin/dev", ports: ["3000:3000"]}],
        services: [%{name: "postgres", image: "postgres:16", env: %{"POSTGRES_PASSWORD" => "secret"}, volumes: ["{data}:/var/lib/postgresql/data"], ports: []}],
        env_vars: %{"RAILS_ENV" => "development"}
      }

      output = Compose.generate(ws, tmp_dir, "abcd")
      config = Jason.decode!(output)

      # Has workspace service
      assert config["services"]["workspace"]
      assert config["services"]["workspace"]["command"] == "sleep infinity"

      # Has dev service
      assert config["services"]["dev"]
      assert config["services"]["dev"]["command"] == "bin/dev"
      # Host ports are stripped — only container port remains
      assert "3000" in config["services"]["dev"]["ports"]

      # Has postgres service
      assert config["services"]["postgres"]
      assert config["services"]["postgres"]["image"] == "postgres:16"
      assert "POSTGRES_PASSWORD=secret" in config["services"]["postgres"]["environment"]

      # Has volumes
      assert Map.has_key?(config["volumes"], "cache-abcd")
      assert Map.has_key?(config["volumes"], "postgres-data-abcd")
    end

    test "generates minimal compose with only workspace", %{tmp_dir: tmp_dir} do
      ws = %Workspace{
        dockerfile: "FROM ubuntu:24.04",
        processes: [],
        services: []
      }

      output = Compose.generate(ws, tmp_dir, "1234")
      config = Jason.decode!(output)

      assert config["services"]["workspace"]
      assert map_size(config["services"]) == 1
    end

    test "build context is project root with dockerfile in .boomlooper/workspace", %{tmp_dir: tmp_dir} do
      ws = %Workspace{
        dockerfile: "FROM ruby:3.4",
        processes: [%{name: "dev", command: "bin/dev", ports: ["3000"]}],
        services: []
      }

      output = Compose.generate(ws, tmp_dir, "abcd")
      config = Jason.decode!(output)

      assert config["services"]["workspace"]["build"]["context"] == tmp_dir
      assert config["services"]["workspace"]["build"]["dockerfile"] == ".boomlooper/workspace/Dockerfile"
      assert config["services"]["dev"]["build"]["context"] == tmp_dir
    end

    test "strips host ports from port mappings", %{tmp_dir: tmp_dir} do
      ws = %Workspace{
        dockerfile: "FROM ruby:3.4",
        processes: [%{name: "dev", command: "bin/dev", ports: ["3001:3000", "8080"]}],
        services: [%{name: "postgres", image: "postgres:16", env: %{}, volumes: [], ports: ["5433:5432"]}]
      }

      output = Compose.generate(ws, tmp_dir, "abcd")
      config = Jason.decode!(output)

      assert config["services"]["dev"]["ports"] == ["3000", "8080"]
      assert config["services"]["postgres"]["ports"] == ["5432"]
    end

    test "project_name uses bl- prefix" do
      assert Compose.project_name("abcd") == "bl-abcd"
    end

    test "compose_path is in .boomlooper/workspace directory" do
      assert Compose.compose_path("/tmp/test") == "/tmp/test/.boomlooper/workspace/docker-compose.yml"
    end
  end

  describe "up_stream/3" do
    test "calls callback with output and returns result" do
      me = self()

      port = Port.open(
        {:spawn_executable, System.find_executable("echo")},
        [:binary, :exit_status, {:args, ["hello", "world"]}]
      )

      result = Compose.collect_port_output(port, fn chunk -> send(me, {:chunk, chunk}) end, "", 5_000)

      assert {:ok, output} = result
      assert output =~ "hello world"
      assert_received {:chunk, _}
    end

    test "returns error on non-zero exit" do
      port = Port.open(
        {:spawn_executable, System.find_executable("sh")},
        [:binary, :exit_status, {:args, ["-c", "echo fail && exit 1"]}]
      )

      result = Compose.collect_port_output(port, fn _ -> :ok end, "", 5_000)

      assert {:error, output} = result
      assert output =~ "fail"
    end
  end
end
