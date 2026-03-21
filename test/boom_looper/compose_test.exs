defmodule BoomLooper.ComposeTest do
  use ExUnit.Case

  alias BoomLooper.{Compose, Workspace}

  describe "generate/3" do
    test "generates compose with workspace, dev, and stock services" do
      ws = %Workspace{
        name: "test-project",
        dockerfile: "FROM ruby:3.4\nWORKDIR /workspace",
        processes: [%{name: "dev", command: "bin/dev", ports: ["3000:3000"]}],
        services: [%{name: "postgres", image: "postgres:16", env: %{"POSTGRES_PASSWORD" => "secret"}, volumes: ["{data}:/var/lib/postgresql/data"], ports: []}],
        env_vars: %{"RAILS_ENV" => "development"}
      }

      output = Compose.generate(ws, "/tmp/test-project", "abcd")
      config = Jason.decode!(output)

      # Has workspace service
      assert config["services"]["workspace"]
      assert config["services"]["workspace"]["command"] == "sleep infinity"
      assert "/tmp/test-project:/workspace" in config["services"]["workspace"]["volumes"]

      # Has dev service
      assert config["services"]["dev"]
      assert config["services"]["dev"]["command"] == "bin/dev"
      assert "3000:3000" in config["services"]["dev"]["ports"]

      # Has postgres service
      assert config["services"]["postgres"]
      assert config["services"]["postgres"]["image"] == "postgres:16"
      assert "POSTGRES_PASSWORD=secret" in config["services"]["postgres"]["environment"]

      # Has volumes
      assert Map.has_key?(config["volumes"], "cache-abcd")
      assert Map.has_key?(config["volumes"], "postgres-data-abcd")
    end

    test "generates minimal compose with only workspace" do
      ws = %Workspace{
        dockerfile: "FROM ubuntu:24.04",
        processes: [],
        services: []
      }

      output = Compose.generate(ws, "/tmp/minimal", "1234")
      config = Jason.decode!(output)

      assert config["services"]["workspace"]
      assert map_size(config["services"]) == 1
    end

    test "project_name uses bl- prefix" do
      assert Compose.project_name("abcd") == "bl-abcd"
    end

    test "compose_path is in .hive directory" do
      assert Compose.compose_path("/tmp/test") == "/tmp/test/.hive/docker-compose.yml"
    end
  end
end
