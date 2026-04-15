defmodule BoomLooper.ComposeTest do
  use ExUnit.Case, async: false

  alias BoomLooper.Compose

  # Process_agent_compose now emits ports assigned by
  # BoomLooper.PortRegistry. Each test clears the registry table so
  # assignments start from the bottom of the range, making the
  # expected output predictable.
  setup do
    BoomLooper.StateKeeper.ensure_tables!()
    :ets.delete_all_objects(:port_registry)
    :ok
  end

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
      assert Enum.any?(web_volumes, &String.starts_with?(&1, "bl-abcd-code:"))
      assert config["volumes"]["bl-abcd-code"]["external"] == true
    end

    test "rejects agent-pinned host ports outright" do
      # Agents must not pin host ports themselves — BoomLooper picks them
      # dynamically and keeps them sticky across restarts. Pinning would
      # collide across workspaces.
      compose = %{
        "services" => %{
          "web" => %{"ports" => ["3001:3000"]}
        }
      }

      assert {:error, msg} =
               Compose.process_agent_compose(Jason.encode!(compose), "abcd")

      assert msg =~ "host port pin"
    end

    test "assigns host ports via PortRegistry (sticky across calls, loopback-bound)" do
      compose = %{
        "services" => %{
          "dev" => %{"ports" => ["3000"]},
          "postgres" => %{"ports" => ["5432"]}
        }
      }

      {:ok, result1} = Compose.process_agent_compose(Jason.encode!(compose), "abcd")
      config1 = Jason.decode!(result1)

      # Every emitted port is loopback-bound via the registry.
      dev_port = hd(config1["services"]["dev"]["ports"])
      pg_port = hd(config1["services"]["postgres"]["ports"])
      assert String.starts_with?(dev_port, "127.0.0.1:")
      assert String.ends_with?(dev_port, ":3000")
      assert String.starts_with?(pg_port, "127.0.0.1:")
      assert String.ends_with?(pg_port, ":5432")
      assert dev_port != pg_port

      # Re-running against the same workspace yields the same ports —
      # the registry entry is sticky.
      {:ok, result2} = Compose.process_agent_compose(Jason.encode!(compose), "abcd")
      config2 = Jason.decode!(result2)
      assert config2["services"]["dev"]["ports"] == [dev_port]
      assert config2["services"]["postgres"]["ports"] == [pg_port]
    end

    test "distinct workspaces get distinct host ports for the same container port" do
      compose = %{"services" => %{"dev" => %{"ports" => ["3000"]}}}

      {:ok, r1} = Compose.process_agent_compose(Jason.encode!(compose), "ws-a")
      {:ok, r2} = Compose.process_agent_compose(Jason.encode!(compose), "ws-b")

      p1 = Jason.decode!(r1)["services"]["dev"]["ports"] |> hd()
      p2 = Jason.decode!(r2)["services"]["dev"]["ports"] |> hd()

      assert p1 != p2
      assert String.ends_with?(p1, ":3000")
      assert String.ends_with?(p2, ":3000")
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
      assert "bl-abcd-code:/workspace" in config["services"]["web"]["volumes"]
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
      assert config["volumes"]["bl-test1-code"]["external"] == true

      # Service volumes reference the code volume correctly
      ws_volumes = config["services"]["workspace"]["volumes"]
      assert Enum.any?(ws_volumes, &String.starts_with?(&1, "bl-test1-code:"))

      # Host port is assigned by PortRegistry and loopback-bound.
      [port_spec] = config["services"]["workspace"]["ports"]
      assert String.starts_with?(port_spec, "127.0.0.1:")
      assert String.ends_with?(port_spec, ":3000")
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
      assert config["volumes"]["bl-xyz1-code"]["external"] == true
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

  describe "validate_no_host_mounts/1 — volumes" do
    test "accepts named-volume short-form mounts" do
      compose = %{
        "services" => %{
          "dev" => %{"volumes" => ["code-ws:/workspace", "cache:/root/.cache:ro"]}
        }
      }

      assert :ok = Compose.validate_no_host_mounts(compose)
    end

    test "accepts ${CODE_VOLUME} placeholder (resolved later)" do
      compose = %{"services" => %{"dev" => %{"volumes" => ["${CODE_VOLUME}:/workspace"]}}}
      assert :ok = Compose.validate_no_host_mounts(compose)
    end

    test "rejects absolute host path in short form" do
      compose = %{"services" => %{"dev" => %{"volumes" => ["/etc:/host/etc:ro"]}}}

      assert {:error, msg} = Compose.validate_no_host_mounts(compose)
      assert msg =~ "host bind mount"
      assert msg =~ "Fix:"
      assert msg =~ "write_file"
    end

    test "rejects relative / home-relative host paths" do
      for source <- ["./src", "../outside", "~", "~/code"] do
        compose = %{"services" => %{"dev" => %{"volumes" => ["#{source}:/workspace"]}}}

        assert {:error, _} = Compose.validate_no_host_mounts(compose),
               "should reject source #{source}"
      end
    end

    test "rejects `type: bind` long-form mount" do
      compose = %{
        "services" => %{
          "dev" => %{
            "volumes" => [
              %{"type" => "bind", "source" => "/etc", "target" => "/host/etc"}
            ]
          }
        }
      }

      assert {:error, msg} = Compose.validate_no_host_mounts(compose)
      assert msg =~ "type: bind"
    end

    test "accepts `type: volume` long-form mount" do
      compose = %{
        "services" => %{
          "dev" => %{
            "volumes" => [%{"type" => "volume", "source" => "data", "target" => "/data"}]
          }
        }
      }

      assert :ok = Compose.validate_no_host_mounts(compose)
    end

    test "rejects top-level volume with host-backed driver_opts.device" do
      compose = %{
        "services" => %{"dev" => %{"volumes" => ["sneaky:/workspace"]}},
        "volumes" => %{
          "sneaky" => %{
            "driver" => "local",
            "driver_opts" => %{"type" => "none", "o" => "bind", "device" => "/etc"}
          }
        }
      }

      assert {:error, msg} = Compose.validate_no_host_mounts(compose)
      assert msg =~ "host path"
    end

    test "accepts top-level volume with external: true" do
      compose = %{
        "services" => %{"dev" => %{"volumes" => ["code:/workspace"]}},
        "volumes" => %{"code" => %{"external" => true}}
      }

      assert :ok = Compose.validate_no_host_mounts(compose)
    end

    test "rejects an attempt to mount the docker socket" do
      compose = %{
        "services" => %{
          "dev" => %{"volumes" => ["/var/run/docker.sock:/var/run/docker.sock"]}
        }
      }

      assert {:error, _} = Compose.validate_no_host_mounts(compose)
    end
  end

  describe "validate_no_host_mounts/1 — host escapes" do
    test "rejects privileged: true" do
      compose = %{"services" => %{"dev" => %{"privileged" => true}}}
      assert {:error, msg} = Compose.validate_no_host_mounts(compose)
      assert msg =~ "privileged"
      assert msg =~ "cap_add"
    end

    test "rejects network_mode: host" do
      compose = %{"services" => %{"dev" => %{"network_mode" => "host"}}}
      assert {:error, msg} = Compose.validate_no_host_mounts(compose)
      assert msg =~ "network_mode: host"
      assert msg =~ "ports:"
    end

    test "rejects pid: host" do
      compose = %{"services" => %{"dev" => %{"pid" => "host"}}}
      assert {:error, msg} = Compose.validate_no_host_mounts(compose)
      assert msg =~ "pid: host"
    end

    test "rejects ipc: host" do
      compose = %{"services" => %{"dev" => %{"ipc" => "host"}}}
      assert {:error, msg} = Compose.validate_no_host_mounts(compose)
      assert msg =~ "ipc: host"
    end

    test "rejects userns_mode: host" do
      compose = %{"services" => %{"dev" => %{"userns_mode" => "host"}}}
      assert {:error, msg} = Compose.validate_no_host_mounts(compose)
      assert msg =~ "userns_mode: host"
    end

    test "rejects non-empty devices:" do
      compose = %{"services" => %{"dev" => %{"devices" => ["/dev/kvm:/dev/kvm"]}}}
      assert {:error, msg} = Compose.validate_no_host_mounts(compose)
      assert msg =~ "devices:"
    end

    test "accepts empty devices list" do
      compose = %{"services" => %{"dev" => %{"devices" => []}}}
      assert :ok = Compose.validate_no_host_mounts(compose)
    end

    test "accepts a perfectly ordinary service" do
      compose = %{
        "services" => %{
          "dev" => %{
            "image" => "node:20",
            "volumes" => ["${CODE_VOLUME}:/workspace"],
            "ports" => ["3000"]
          }
        },
        "volumes" => %{"${CODE_VOLUME}" => %{"external" => true}}
      }

      assert :ok = Compose.validate_no_host_mounts(compose)
    end
  end

  describe "validate_no_host_mounts/1 — ports" do
    test "accepts container-only port specs" do
      compose = %{"services" => %{"dev" => %{"ports" => ["3000", "5432", 6379]}}}
      assert :ok = Compose.validate_no_host_mounts(compose)
    end

    test "rejects a host-pinned port in short form" do
      compose = %{"services" => %{"dev" => %{"ports" => ["8080:3000"]}}}
      assert {:error, msg} = Compose.validate_no_host_mounts(compose)
      assert msg =~ "host port pin is not allowed"
      assert msg =~ "Fix:"
    end

    test "rejects an IP-qualified host port (127.0.0.1:8080:3000)" do
      compose = %{"services" => %{"dev" => %{"ports" => ["127.0.0.1:8080:3000"]}}}
      assert {:error, msg} = Compose.validate_no_host_mounts(compose)
      assert msg =~ "host port pin"
    end

    test "rejects long-form port with `published`" do
      compose = %{
        "services" => %{
          "dev" => %{
            "ports" => [%{"target" => 3000, "published" => 8080, "protocol" => "tcp"}]
          }
        }
      }

      assert {:error, msg} = Compose.validate_no_host_mounts(compose)
      assert msg =~ "host port pin"
    end

    test "accepts long-form port without `published`" do
      compose = %{
        "services" => %{
          "dev" => %{"ports" => [%{"target" => 3000, "protocol" => "tcp"}]}
        }
      }

      assert :ok = Compose.validate_no_host_mounts(compose)
    end
  end

  describe "validate_no_host_mounts/1 — networks" do
    test "accepts the default (no networks declared)" do
      compose = %{"services" => %{"dev" => %{"image" => "x"}}}
      assert :ok = Compose.validate_no_host_mounts(compose)
    end

    test "accepts internal custom networks" do
      compose = %{
        "services" => %{
          "dev" => %{"image" => "x", "networks" => ["frontend"]}
        },
        "networks" => %{"frontend" => %{}}
      }

      assert :ok = Compose.validate_no_host_mounts(compose)
    end

    test "rejects a top-level external network" do
      compose = %{
        "services" => %{"dev" => %{"image" => "x", "networks" => ["shared"]}},
        "networks" => %{"shared" => %{"external" => true}}
      }

      assert {:error, msg} = Compose.validate_no_host_mounts(compose)
      assert msg =~ "external: true"
      assert msg =~ "isolated per workspace"
    end

    test "rejects a service-attached external network (long form)" do
      compose = %{
        "services" => %{
          "dev" => %{
            "image" => "x",
            "networks" => %{"shared" => %{"external" => true}}
          }
        }
      }

      assert {:error, msg} = Compose.validate_no_host_mounts(compose)
      assert msg =~ "external"
    end
  end

  describe "process_agent_compose/3 boundary" do
    test "returns error when any service has a host bind mount" do
      compose = ~s|{"services":{"dev":{"image":"x","volumes":["/etc:/host/etc"]}}}|
      assert {:error, msg} = Compose.process_agent_compose(compose, "ws-test")
      assert msg =~ "host bind mount"
    end

    test "returns error for privileged services" do
      compose = ~s|{"services":{"dev":{"image":"x","privileged":true}}}|
      assert {:error, msg} = Compose.process_agent_compose(compose, "ws-test")
      assert msg =~ "privileged"
    end

    test "returns error for host-pinned ports" do
      compose = ~s|{"services":{"dev":{"image":"x","ports":["8080:3000"]}}}|
      assert {:error, msg} = Compose.process_agent_compose(compose, "ws-test")
      assert msg =~ "host port pin"
    end

    test "returns error for external networks" do
      compose = ~s|{"services":{"dev":{"image":"x"}},"networks":{"shared":{"external":true}}}|
      assert {:error, msg} = Compose.process_agent_compose(compose, "ws-test")
      assert msg =~ "external"
    end

    test "succeeds for a named-volume compose" do
      compose = ~s|{"services":{"dev":{"image":"x","volumes":["${CODE_VOLUME}:/workspace"]}}}|
      assert {:ok, json} = Compose.process_agent_compose(compose, "ws-test")
      assert json =~ "\"external\": true"
    end

    test "binds emitted ports to 127.0.0.1 (loopback-only)" do
      compose = ~s|{"services":{"dev":{"image":"x","ports":["3000","5432"]}}}|
      assert {:ok, json} = Compose.process_agent_compose(compose, "ws-ports-test")
      decoded = Jason.decode!(json)
      ports = decoded["services"]["dev"]["ports"]

      for port <- ports do
        assert String.starts_with?(port, "127.0.0.1:"),
               "port #{inspect(port)} should be bound to 127.0.0.1 only"
      end
    end

    test "re-processing the same workspace yields the same registry-assigned port" do
      compose = ~s|{"services":{"dev":{"image":"x","ports":["3000"]}}}|

      {:ok, json1} = Compose.process_agent_compose(compose, "ws-sticky")
      {:ok, json2} = Compose.process_agent_compose(compose, "ws-sticky")

      assert Jason.decode!(json1)["services"]["dev"]["ports"] ==
               Jason.decode!(json2)["services"]["dev"]["ports"]
    end
  end
end
