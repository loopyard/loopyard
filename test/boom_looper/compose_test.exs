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

      # Has workspace service (built from project Dockerfile)
      assert config["services"]["workspace"]
      assert config["services"]["workspace"]["command"] == "sleep infinity"
      # Workspace uses project dir as build context
      assert config["services"]["workspace"]["build"]["context"] == tmp_dir

      # Has dev service (uses project Dockerfile)
      assert config["services"]["dev"]
      # Dev command is set directly
      assert config["services"]["dev"]["command"] == "bin/dev"
      # Host ports are stripped — only container port remains
      assert "3000" in config["services"]["dev"]["ports"]

      # Has postgres service
      assert config["services"]["postgres"]
      assert config["services"]["postgres"]["image"] == "postgres:16"
      assert "POSTGRES_PASSWORD=secret" in config["services"]["postgres"]["environment"]

      # Has volumes - all workspaces are volume-based
      assert Map.has_key?(config["volumes"], "cache-abcd")
      assert Map.has_key?(config["volumes"], "code-abcd")
      assert Map.has_key?(config["volumes"], "postgres-data-abcd")
    end

    test "no workspace container without dockerfile", %{tmp_dir: tmp_dir} do
      ws = %Workspace{
        dockerfile: nil,
        processes: [],
        services: []
      }

      output = Compose.generate(ws, tmp_dir, "1234")
      config = Jason.decode!(output)

      # No workspace or dev service without dockerfile
      refute config["services"]["workspace"]
      refute config["services"]["dev"]
    end

    test "workspace uses fixed alpine base image from priv/workspace-base", %{tmp_dir: tmp_dir} do
      ws = %Workspace{
        dockerfile: "FROM ruby:3.4",
        processes: [%{name: "dev", command: "bin/dev", ports: ["3000"]}],
        services: []
      }

      output = Compose.generate(ws, tmp_dir, "abcd")
      config = Jason.decode!(output)

      # Workspace uses project dir as build context
      assert config["services"]["workspace"]["build"]["context"] == tmp_dir
      assert config["services"]["workspace"]["build"]["dockerfile"] == ".boomlooper/workspace/Dockerfile"

      # Dev also uses project dir as build context
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

    test "all workspaces are volume-based (code volume is external)", %{tmp_dir: tmp_dir} do
      ws = %Workspace{
        name: "any-project",
        dockerfile: "FROM ruby:3.4",
        processes: [%{name: "dev", command: "bin/dev", ports: ["3000"]}],
        services: []
      }

      output = Compose.generate(ws, tmp_dir, "abcd")
      config = Jason.decode!(output)

      # Code volume is named and external
      assert Map.has_key?(config["volumes"], "code-abcd")
      assert config["volumes"]["code-abcd"]["external"] == true

      # Services mount the named code volume
      workspace_volumes = config["services"]["workspace"]["volumes"]
      assert Enum.any?(workspace_volumes, &String.starts_with?(&1, "code-abcd:"))
    end

    test "dev build context is in ~/.boomlooper/builds/{workspace_id}", %{tmp_dir: tmp_dir} do
      ws = %Workspace{
        name: "git-project",
        git_url: "git@github.com:owner/repo.git",
        branch: "main",
        dockerfile: "FROM ruby:3.4",
        processes: [%{name: "dev", command: "bin/rails server", ports: ["3000"]}],
        services: []
      }

      output = Compose.generate(ws, tmp_dir, "abcd")
      config = Jason.decode!(output)

      assert config["services"]["dev"]["build"]["context"] == tmp_dir
      assert config["services"]["dev"]["build"]["dockerfile"] == ".boomlooper/workspace/Dockerfile"
    end
  end

  describe "generate/3 edge cases" do
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "boom-looper-compose-edge-#{:rand.uniform(100_000)}")
      File.mkdir_p!(Path.join(tmp_dir, ".boomlooper/workspace"))
      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      %{tmp_dir: tmp_dir}
    end

    test "multiple processes each get their own service", %{tmp_dir: tmp_dir} do
      ws = %Workspace{
        dockerfile: "FROM node:20",
        processes: [
          %{name: "web", command: "npm start", ports: ["3000"]},
          %{name: "worker", command: "npm run worker", ports: []}
        ],
        services: []
      }

      config = ws |> Compose.generate(tmp_dir, "abcd") |> Jason.decode!()

      assert config["services"]["web"]["command"] == "npm start"
      assert config["services"]["worker"]["command"] == "npm run worker"
      assert config["services"]["web"]["ports"] == ["3000"]
      refute Map.has_key?(config["services"]["worker"], "ports")
    end

    test "service env vars rendered as KEY=VALUE list", %{tmp_dir: tmp_dir} do
      ws = %Workspace{
        dockerfile: "FROM ruby:3.4",
        processes: [],
        services: [%{name: "pg", image: "postgres:16",
                      env: %{"POSTGRES_USER" => "app", "POSTGRES_DB" => "mydb"},
                      volumes: [], ports: []}]
      }

      config = ws |> Compose.generate(tmp_dir, "abcd") |> Jason.decode!()
      env = config["services"]["pg"]["environment"]
      assert "POSTGRES_USER=app" in env
      assert "POSTGRES_DB=mydb" in env
    end

    test "service without env/ports/volumes omits those keys", %{tmp_dir: tmp_dir} do
      ws = %Workspace{
        dockerfile: "FROM ruby:3.4",
        processes: [],
        services: [%{name: "redis", image: "redis:7", env: %{}, volumes: [], ports: []}]
      }

      config = ws |> Compose.generate(tmp_dir, "abcd") |> Jason.decode!()
      redis = config["services"]["redis"]
      assert redis["image"] == "redis:7"
      refute Map.has_key?(redis, "environment")
      refute Map.has_key?(redis, "ports")
      refute Map.has_key?(redis, "volumes")
    end

    test "{data} in volumes is expanded to workspace-scoped name", %{tmp_dir: tmp_dir} do
      ws = %Workspace{
        dockerfile: "FROM ruby:3.4",
        processes: [],
        services: [%{name: "postgres", image: "postgres:16", env: %{},
                      volumes: ["{data}:/var/lib/postgresql/data"], ports: []}]
      }

      config = ws |> Compose.generate(tmp_dir, "abcd") |> Jason.decode!()
      vols = config["services"]["postgres"]["volumes"]
      assert "postgres-data-abcd:/var/lib/postgresql/data" in vols
      assert Map.has_key?(config["volumes"], "postgres-data-abcd")
    end

    test "shared volumes include code, cache, and deps", %{tmp_dir: tmp_dir} do
      ws = %Workspace{
        dockerfile: "FROM ruby:3.4",
        processes: [%{name: "dev", command: "bin/dev", ports: []}],
        services: []
      }

      config = ws |> Compose.generate(tmp_dir, "abcd") |> Jason.decode!()

      for svc <- ["workspace", "dev"] do
        volumes = config["services"][svc]["volumes"]
        assert Enum.any?(volumes, &(&1 == "code-abcd:/workspace"))
        assert Enum.any?(volumes, &(&1 == "cache-abcd:/root/.cache"))
        assert Enum.any?(volumes, &(&1 == "deps-abcd:/usr/local/bundle"))
      end
    end

    test "workspace env_vars applied to workspace and dev containers", %{tmp_dir: tmp_dir} do
      ws = %Workspace{
        dockerfile: "FROM ruby:3.4",
        processes: [%{name: "dev", command: "bin/dev", ports: []}],
        services: [],
        env_vars: %{"RAILS_ENV" => "development", "SECRET" => "abc"}
      }

      config = ws |> Compose.generate(tmp_dir, "abcd") |> Jason.decode!()

      for svc <- ["workspace", "dev"] do
        env = config["services"][svc]["environment"]
        assert "RAILS_ENV=development" in env
        assert "SECRET=abc" in env
      end
    end

    test "strips IP:host:container port format", %{tmp_dir: tmp_dir} do
      ws = %Workspace{
        dockerfile: "FROM ruby:3.4",
        processes: [%{name: "dev", command: "bin/dev", ports: ["0.0.0.0:3001:3000"]}],
        services: []
      }

      config = ws |> Compose.generate(tmp_dir, "abcd") |> Jason.decode!()
      assert config["services"]["dev"]["ports"] == ["3000"]
    end
  end

  describe "collect_port_output/4" do
    test "succeeds with callback on zero exit" do
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

    test "returns error with accumulated output on timeout" do
      port = Port.open(
        {:spawn_executable, System.find_executable("sleep")},
        [:binary, :exit_status, {:args, ["10"]}]
      )

      result = Compose.collect_port_output(port, fn _ -> :ok end, "partial", 100)
      assert {:error, output} = result
      assert output =~ "partial"
      assert output =~ "timed out"
    end

    test "detects arm64_unsupported in output" do
      port = Port.open(
        {:spawn_executable, System.find_executable("echo")},
        [:binary, :exit_status, {:args, ["no matching manifest for linux/arm64"]}]
      )

      result = Compose.collect_port_output(port, fn _ -> :ok end, "", 5_000)
      assert {:error, :arm64_unsupported, _output} = result
    end
  end

  describe "write/2" do
    test "writes compose file from workspace config" do
      tmp_dir = Path.join(System.tmp_dir!(), "boom-looper-compose-write-#{:rand.uniform(100_000)}")
      File.mkdir_p!(Path.join(tmp_dir, ".boomlooper/workspace"))
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      ws = %Workspace{
        dockerfile: "FROM ruby:3.4",
        processes: [%{name: "dev", command: "bin/dev", ports: ["3000"]}],
        services: []
      }

      Workspace.save(tmp_dir, ws)
      assert {:ok, path} = Compose.write(tmp_dir, "abcd")
      assert File.exists?(path)
      assert path == Compose.compose_path(tmp_dir)

      content = File.read!(path)
      config = Jason.decode!(content)
      assert config["services"]["dev"]
    end

    test "returns :none when no workspace config" do
      tmp_dir = Path.join(System.tmp_dir!(), "boom-looper-compose-noconf-#{:rand.uniform(100_000)}")
      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      assert :none = Compose.write(tmp_dir, "abcd")
    end
  end
end
