defmodule Loopyard.ComposeSecurityTest do
  @moduledoc """
  Table-driven regression suite for `Loopyard.Compose.validate_no_host_mounts/1`
  and the compose processing seams (`normalize_code_volume_names`,
  `inject_identity_home`).

  Every host-escape reject path in `lib/loopyard/compose.ex` gets a test here so
  that a regression that silently drops a check (e.g. someone deletes a `cond`
  arm) fails CI instead of shipping a sandbox hole.
  """
  use ExUnit.Case, async: false

  alias Loopyard.Compose

  setup do
    Loopyard.StateKeeper.ensure_tables!()
    :ets.delete_all_objects(:port_registry)

    on_exit(fn -> :ets.delete_all_objects(:port_registry) end)
    :ok
  end

  # Wrap a service map in a minimal compose document.
  defp svc_compose(svc), do: %{"services" => %{"web" => svc}}

  describe "validate_no_host_mounts/1 — short-form host bind mounts" do
    # Every short-form source matching host_path?/1 must be rejected.
    for {label, mount} <- [
          {"absolute path", "/etc:/host"},
          {"dot-slash relative", "./src:/app"},
          {"home tilde", "~/.ssh:/keys"},
          {"parent dir", "../secrets:/secrets"},
          {"bare dot source", ".:/app"},
          {"bare dotdot source", "..:/app"}
        ] do
      test "rejects short-form #{label} (#{mount})" do
        compose = svc_compose(%{"volumes" => [unquote(mount)]})
        assert {:error, reason} = Compose.validate_no_host_mounts(compose)
        assert reason =~ "host bind mount is not allowed"
      end
    end

    test "rejects empty volume source" do
      compose = svc_compose(%{"volumes" => [":/dst"]})
      assert {:error, reason} = Compose.validate_no_host_mounts(compose)
      assert reason =~ "empty volume source"
    end
  end

  describe "validate_no_host_mounts/1 — long-form type: bind" do
    test "rejects a long-form bind volume entry" do
      compose =
        svc_compose(%{
          "volumes" => [
            %{"type" => "bind", "source" => "/etc", "target" => "/host"}
          ]
        })

      assert {:error, reason} = Compose.validate_no_host_mounts(compose)
      assert reason =~ "`type: bind` is not allowed"
    end

    test "accepts long-form type: volume and type: tmpfs" do
      compose =
        svc_compose(%{
          "volumes" => [
            %{"type" => "volume", "source" => "named", "target" => "/data"},
            %{"type" => "tmpfs", "target" => "/tmp"}
          ]
        })

      assert :ok = Compose.validate_no_host_mounts(compose)
    end

    test "rejects an unsupported long-form volume type" do
      compose =
        svc_compose(%{"volumes" => [%{"type" => "npipe", "target" => "/x"}]})

      assert {:error, reason} = Compose.validate_no_host_mounts(compose)
      assert reason =~ "unsupported volume type"
    end
  end

  describe "validate_no_host_mounts/1 — host-escape runtime grants" do
    # Each of these is a single-key host escape in check_host_escape/2.
    for {label, svc, fragment} <- [
          {"privileged", %{"privileged" => true}, "`privileged: true` is not allowed"},
          {"network_mode host", %{"network_mode" => "host"},
           "`network_mode: host` is not allowed"},
          {"pid host", %{"pid" => "host"}, "`pid: host` is not allowed"},
          {"ipc host", %{"ipc" => "host"}, "`ipc: host` is not allowed"},
          {"userns_mode host", %{"userns_mode" => "host"},
           "`userns_mode: host` is not allowed"},
          {"devices", %{"devices" => ["/dev/sda:/dev/sda"]}, "`devices:` is not allowed"}
        ] do
      test "rejects #{label}" do
        assert {:error, reason} =
                 Compose.validate_no_host_mounts(svc_compose(unquote(Macro.escape(svc))))

        assert reason =~ unquote(fragment)
      end
    end

    test "accepts an empty devices list (no escape)" do
      # check_host_escape only fires when devices is a non-empty list.
      assert :ok = Compose.validate_no_host_mounts(svc_compose(%{"devices" => []}))
    end
  end

  describe "validate_no_host_mounts/1 — host port pins" do
    for {label, port} <- [
          {"host:container", "8080:3000"},
          {"ip:host:container", "127.0.0.1:8080:3000"}
        ] do
      test "rejects short-form #{label} (#{port})" do
        compose = svc_compose(%{"ports" => [unquote(port)]})
        assert {:error, reason} = Compose.validate_no_host_mounts(compose)
        assert reason =~ "host port pin is not allowed"
      end
    end

    test "rejects long-form published: port" do
      compose =
        svc_compose(%{"ports" => [%{"published" => 8080, "target" => 3000}]})

      assert {:error, reason} = Compose.validate_no_host_mounts(compose)
      assert reason =~ "host port pin is not allowed"
    end

    test "accepts container-only ports (string and integer)" do
      assert :ok = Compose.validate_no_host_mounts(svc_compose(%{"ports" => ["3000"]}))
      assert :ok = Compose.validate_no_host_mounts(svc_compose(%{"ports" => [3000]}))
    end
  end

  describe "validate_no_host_mounts/1 — external networks" do
    test "rejects a top-level external network" do
      compose = %{
        "services" => %{"web" => %{}},
        "networks" => %{"foo" => %{"external" => true}}
      }

      assert {:error, reason} = Compose.validate_no_host_mounts(compose)
      assert reason =~ "top-level network"
      assert reason =~ "`external: true` is not allowed"
    end

    test "rejects a per-service external network" do
      compose = %{
        "services" => %{
          "web" => %{"networks" => %{"foo" => %{"external" => true}}}
        }
      }

      assert {:error, reason} = Compose.validate_no_host_mounts(compose)
      assert reason =~ "declares `external: true`"
    end

    test "accepts a top-level non-external network" do
      compose = %{
        "services" => %{"web" => %{"networks" => ["backend"]}},
        "networks" => %{"backend" => %{}}
      }

      assert :ok = Compose.validate_no_host_mounts(compose)
    end
  end

  describe "validate_no_host_mounts/1 — top-level host-backed volumes" do
    test "rejects a top-level volume whose driver_opts.device is a host path" do
      compose = %{
        "services" => %{"web" => %{}},
        "volumes" => %{
          "escape" => %{
            "driver" => "local",
            "driver_opts" => %{
              "type" => "none",
              "o" => "bind",
              "device" => "/host/data"
            }
          }
        }
      }

      assert {:error, reason} = Compose.validate_no_host_mounts(compose)
      assert reason =~ "driver_opts.device points at a host path"
    end

    test "accepts a top-level volume with driver_opts.device that is NOT a host path" do
      # A device that doesn't look like a host path (no leading /, ., ~) passes.
      compose = %{
        "services" => %{"web" => %{}},
        "volumes" => %{
          "nfsvol" => %{
            "driver" => "local",
            "driver_opts" => %{"device" => ":/exported/path"}
          }
        }
      }

      assert :ok = Compose.validate_no_host_mounts(compose)
    end

    test "accepts external and empty top-level volume declarations" do
      compose = %{
        "services" => %{"web" => %{}},
        "volumes" => %{
          "ext" => %{"external" => true},
          "empty" => %{},
          "nilspec" => nil
        }
      }

      assert :ok = Compose.validate_no_host_mounts(compose)
    end
  end

  describe "validate_no_host_mounts/1 — valid compose passes" do
    test "named volumes + container-only ports + tmpfs all pass" do
      compose = %{
        "services" => %{
          "web" => %{
            "image" => "myapp",
            "volumes" => ["${CODE_VOLUME}:/workspace", "appdata:/data"],
            "ports" => ["3000"],
            "cap_add" => ["NET_ADMIN"]
          },
          "db" => %{
            "image" => "postgres:16",
            "volumes" => ["pgdata:/var/lib/postgresql/data"]
          }
        },
        "volumes" => %{
          "appdata" => %{},
          "pgdata" => nil
        }
      }

      assert :ok = Compose.validate_no_host_mounts(compose)
    end
  end

  describe "process_agent_compose/2 rejects host escapes end-to-end" do
    # Confirm the validator is wired into the public entrypoint, not just
    # callable in isolation.
    test "rejects a short-form bind mount" do
      compose = svc_compose(%{"volumes" => ["/etc:/host"]})

      assert {:error, reason} = Compose.process_agent_compose(Jason.encode!(compose), "abcd")
      assert reason =~ "host bind mount is not allowed"
    end

    test "rejects privileged: true" do
      compose = svc_compose(%{"privileged" => true})

      assert {:error, reason} = Compose.process_agent_compose(Jason.encode!(compose), "abcd")
      assert reason =~ "`privileged: true` is not allowed"
    end

    test "rejects a host-backed top-level volume" do
      compose = %{
        "services" => %{"web" => %{}},
        "volumes" => %{
          "escape" => %{"driver_opts" => %{"device" => "/host/data"}}
        }
      }

      assert {:error, reason} = Compose.process_agent_compose(Jason.encode!(compose), "abcd")
      assert reason =~ "driver_opts.device points at a host path"
    end
  end

  describe "normalize_code_volume_names (fork safety)" do
    test "rewrites a hardcoded foreign code-volume name to THIS workspace's code volume" do
      # An agent that hardcoded the SOURCE workspace's code volume name instead
      # of ${CODE_VOLUME} would otherwise have the FORK mount the SOURCE's code.
      compose = %{
        "services" => %{
          "web" => %{"volumes" => ["code:/workspace"]}
        },
        "volumes" => %{
          # Top-level external volume pinned to ANOTHER workspace's code volume.
          "code" => %{"external" => true, "name" => "loopyard-OTHER-code"}
        }
      }

      {:ok, result} = Compose.process_agent_compose(Jason.encode!(compose), "mine")
      config = Jason.decode!(result)

      # The foreign name must be rewritten to THIS workspace's code volume.
      assert config["volumes"]["code"]["name"] == "loopyard-mine-code"
    end

    test "leaves an unrelated named volume (postgres-data) alone" do
      compose = %{
        "services" => %{
          "db" => %{"volumes" => ["pg:/var/lib/postgresql/data"]}
        },
        "volumes" => %{
          "pg" => %{"name" => "postgres-data"}
        }
      }

      {:ok, result} = Compose.process_agent_compose(Jason.encode!(compose), "mine")
      config = Jason.decode!(result)

      # postgres-data doesn't match the loopyard-*-code shape, so it's untouched.
      assert config["volumes"]["pg"]["name"] == "postgres-data"
    end

    test "leaves THIS workspace's own code-volume name alone (no needless rewrite)" do
      compose = %{
        "services" => %{"web" => %{"volumes" => ["code:/workspace"]}},
        "volumes" => %{"code" => %{"external" => true, "name" => "loopyard-mine-code"}}
      }

      {:ok, result} = Compose.process_agent_compose(Jason.encode!(compose), "mine")
      config = Jason.decode!(result)

      assert config["volumes"]["code"]["name"] == "loopyard-mine-code"
    end
  end

  describe "inject_identity_home" do
    # Workstation.current/0 resolves (and bootstraps if needed) a real identity.
    # We resolve it the same way the code does and assert against it rather than
    # hardcoding a value.
    setup do
      identity = Loopyard.Workstation.current()

      %{
        identity: identity,
        home_volume: Loopyard.Workstation.home_volume(identity),
        home_path: "/home/#{identity}"
      }
    end

    test "mounts the identity HOME volume + sets HOME + declares it external on the workspace service",
         %{identity: _identity, home_volume: home_volume, home_path: home_path} do
      compose = %{
        "services" => %{
          "workspace" => %{"volumes" => ["${CODE_VOLUME}:/workspace"]}
        }
      }

      {:ok, result} = Compose.process_agent_compose(Jason.encode!(compose), "abcd")
      config = Jason.decode!(result)

      ws = config["services"]["workspace"]

      # Home volume mounted at /home/<identity>
      assert "#{home_volume}:#{home_path}" in ws["volumes"]

      # HOME env points at the home path (environment is the list shape here).
      assert "HOME=#{home_path}" in ws["environment"]

      # Home volume declared external at the top level.
      assert config["volumes"][home_volume]["external"] == true
    end

    test "does NOT inject identity into app services like `dev`", %{
      home_volume: home_volume,
      home_path: home_path
    } do
      compose = %{
        "services" => %{
          "workspace" => %{"volumes" => ["${CODE_VOLUME}:/workspace"]},
          "dev" => %{"image" => "myapp", "volumes" => ["appdata:/data"]}
        }
      }

      {:ok, result} = Compose.process_agent_compose(Jason.encode!(compose), "abcd")
      config = Jason.decode!(result)

      dev = config["services"]["dev"]

      # dev is cattle: no home mount, no HOME env.
      refute "#{home_volume}:#{home_path}" in (dev["volumes"] || [])
      refute "HOME=#{home_path}" in (dev["environment"] || [])
    end

    test "leaves a compose with no `workspace` service untouched (no identity injected)", %{
      home_volume: home_volume
    } do
      compose = %{
        "services" => %{"dev" => %{"image" => "myapp"}}
      }

      {:ok, result} = Compose.process_agent_compose(Jason.encode!(compose), "abcd")
      config = Jason.decode!(result)

      # No workspace service → inject_identity_home is a no-op for the home volume.
      refute Map.has_key?(config["volumes"] || %{}, home_volume)
    end
  end
end
