defmodule Loopyard.ComposeTest do
  use ExUnit.Case, async: false

  alias Loopyard.Compose

  setup do
    Loopyard.StateKeeper.ensure_tables!()
    :ets.delete_all_objects(:port_registry)

    on_exit(fn -> :ets.delete_all_objects(:port_registry) end)
    :ok
  end

  describe "project_name/1" do
    test "uses loopyard- prefix" do
      assert Compose.project_name("abcd") == "loopyard-abcd"
    end
  end

  describe "compose_path/1" do
    test "is in .loopyard/workspace directory" do
      assert Compose.compose_path("/tmp/test") ==
               "/tmp/test/.loopyard/workspace/docker-compose.yml"
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
      assert Enum.any?(web_volumes, &String.starts_with?(&1, "loopyard-abcd-code:"))
      assert config["volumes"]["loopyard-abcd-code"]["external"] == true
    end

    test "rejects pinned host ports with a clear error" do
      compose = %{
        "services" => %{
          "web" => %{
            "ports" => ["3001:3000", "8080"]
          }
        }
      }

      assert {:error, msg} = Compose.process_agent_compose(Jason.encode!(compose), "abcd")
      assert msg =~ "host port pin is not allowed"
    end

    test "container-only ports become loopback-ephemeral (Docker picks the host port)" do
      compose = %{
        "services" => %{
          "web" => %{
            "ports" => ["8080", "3000"]
          }
        }
      }

      {:ok, result} = Compose.process_agent_compose(Jason.encode!(compose), "abcd")
      config = Jason.decode!(result)

      # Every port becomes 127.0.0.1::<container_port> — Docker picks ephemeral,
      # our proxy owns the user-facing port.
      assert config["services"]["web"]["ports"] == [
               "127.0.0.1::8080",
               "127.0.0.1::3000"
             ]
    end

    test "multiple services each get registry-assigned ports" do
      compose = %{
        "services" => %{
          "dev" => %{"ports" => ["3000"]},
          "postgres" => %{"ports" => ["5432"]}
        }
      }

      {:ok, result} = Compose.process_agent_compose(Jason.encode!(compose), "abcd")
      config = Jason.decode!(result)

      assert config["services"]["dev"]["ports"] == ["127.0.0.1::3000"]
      assert config["services"]["postgres"]["ports"] == ["127.0.0.1::5432"]

      # Registry has entries for both
      entries = Loopyard.PortRegistry.list_for_workspace("abcd")
      assert length(entries) == 2
      assert Enum.any?(entries, &(&1.service == "dev" && &1.container_port == 3000))
      assert Enum.any?(entries, &(&1.service == "postgres" && &1.container_port == 5432))
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
      assert "loopyard-abcd-code:/workspace" in config["services"]["web"]["volumes"]
    end
  end

  describe "process_agent_compose/2 structural validation" do
    test "output is valid JSON and has required top-level keys" do
      compose = """
      services:
        workspace:
          build: .
          volumes:
            - ${CODE_VOLUME}:/workspace
          ports:
            - "3000"
        postgres:
          image: postgres:16
          volumes:
            - pgdata:/var/lib/postgresql/data
      volumes:
        pgdata:
      """

      {:ok, result} = Compose.process_agent_compose(compose, "test1")
      assert {:ok, config} = Jason.decode(result)

      # Top-level structure
      assert Map.has_key?(config, "services")
      assert Map.has_key?(config, "volumes")

      # Code volume declared as external with canonical name
      assert config["volumes"]["loopyard-test1-code"]["external"] == true

      # Service volumes reference the code volume correctly
      ws_volumes = config["services"]["workspace"]["volumes"]
      assert Enum.any?(ws_volumes, &String.starts_with?(&1, "loopyard-test1-code:"))

      # Ports become loopback-ephemeral for Docker; proxy owns user-facing port
      assert config["services"]["workspace"]["ports"] == ["127.0.0.1::3000"]
    end

    test "handles agent-written literal volume names (not ${CODE_VOLUME})" do
      # Agents sometimes write the volume name literally instead of using
      # the placeholder. process_agent_compose should correct the volume
      # declaration regardless.
      compose = %{
        "services" => %{
          "workspace" => %{
            "volumes" => ["my-code-vol:/workspace"]
          }
        },
        "volumes" => %{
          "my-code-vol" => %{"external" => true}
        }
      }

      {:ok, result} = Compose.process_agent_compose(Jason.encode!(compose), "xyz1")
      config = Jason.decode!(result)

      # The canonical code volume MUST be declared
      assert config["volumes"]["loopyard-xyz1-code"]["external"] == true
    end

    test "preserves non-code service volumes" do
      compose = %{
        "services" => %{
          "postgres" => %{
            "image" => "postgres:16",
            "volumes" => ["pgdata:/var/lib/postgresql/data"]
          }
        },
        "volumes" => %{
          "pgdata" => nil
        }
      }

      {:ok, result} = Compose.process_agent_compose(Jason.encode!(compose), "pres")
      config = Jason.decode!(result)

      # pgdata should still be there
      assert Map.has_key?(config["volumes"], "pgdata")
      # postgres service volumes unchanged
      assert "pgdata:/var/lib/postgresql/data" in config["services"]["postgres"]["volumes"]
    end
  end
end
