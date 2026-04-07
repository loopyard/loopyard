defmodule BoomLooper.ComposeTest do
  use ExUnit.Case

  alias BoomLooper.Compose

  describe "project_name/1" do
    test "uses bl- prefix" do
      assert Compose.project_name("abcd") == "bl-abcd"
    end
  end

  describe "compose_path/1" do
    test "is in .boomlooper/workspace directory" do
      assert Compose.compose_path("/tmp/test") == "/tmp/test/.boomlooper/workspace/docker-compose.yml"
    end
  end

  describe "process_agent_compose/2" do
    test "replaces ${CODE_VOLUME} placeholder with actual volume name" do
      compose = %{
        "services" => %{
          "web" => %{
            "volumes" => ["${CODE_VOLUME}:/workspace"],
            "ports" => ["3000"]
          }
        },
        "volumes" => %{
          "code" => %{"external" => true}
        }
      }

      {:ok, result} = Compose.process_agent_compose(Jason.encode!(compose), "abcd")
      config = Jason.decode!(result)

      web_volumes = config["services"]["web"]["volumes"]
      assert Enum.any?(web_volumes, &String.starts_with?(&1, "code-abcd:"))
      assert config["volumes"]["code-abcd"]["external"] == true
    end

    test "strips host ports from port mappings" do
      compose = %{
        "services" => %{
          "web" => %{
            "ports" => ["3001:3000", "8080", "0.0.0.0:4000:4000"]
          }
        }
      }

      {:ok, result} = Compose.process_agent_compose(Jason.encode!(compose), "abcd")
      config = Jason.decode!(result)

      assert config["services"]["web"]["ports"] == ["3000", "8080", "4000"]
    end

    test "handles YAML input" do
      yaml = """
      services:
        web:
          build: .
          ports:
            - "3000"
          volumes:
            - ${CODE_VOLUME}:/workspace
      """

      {:ok, result} = Compose.process_agent_compose(yaml, "abcd")
      config = Jason.decode!(result)

      assert config["services"]["web"]["build"] == "."
      assert "code-abcd:/workspace" in config["services"]["web"]["volumes"]
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
end
