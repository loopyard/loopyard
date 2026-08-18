defmodule Loopyard.Compose do
  @moduledoc """
  Docker Compose operations for workspaces.

  Agents write docker-compose.yml directly via loopyard-container tools.
  This module processes those files and runs compose commands.
  """

  alias Loopyard.Workspace

  @doc """
  Process an agent-written docker-compose.yml with minimal fixups.
  Agents write standard compose syntax. We:
  1. Replace ${CODE_VOLUME} placeholder with actual volume name
  2. Ensure the code volume is declared as external
  3. Assign host ports via `Loopyard.PortRegistry` (sticky per workspace)

  All emitted port specs are `"127.0.0.1:<registry_port>:<container>"` — the
  loopback binding keeps ports off the LAN by default; explicit exposure
  will be a separate TCP proxy layer (v2).
  """
  def process_agent_compose(compose_content, workspace_id, _opts \\ []) do
    code_volume = Workspace.volume_name_for(workspace_id)

    # Placeholders resolve HERE, at run time, so the file on disk stays portable
    # across branches. (They used to resolve at write time, which baked one
    # workspace's id into a file git carries to every branch — see
    # Tools.Container.WriteFile.)
    compose_content = String.replace(compose_content, "${WORKSPACE_ID}", workspace_id)

    case parse_compose(compose_content) do
      {:ok, compose} ->
        with :ok <- validate_no_host_mounts(compose) do
          compose = process_services(compose, code_volume, workspace_id)
          compose = normalize_code_volume_names(compose, code_volume)
          compose = ensure_code_volume(compose, code_volume)
          compose = inject_identity_home(compose)
          {:ok, Jason.encode!(compose, pretty: true)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Mount the operator's identity $HOME volume into the agent's bench
  # service (`workspace`) so an agent exec'ing there inherits the same
  # logins/tools (gh/claude/fly) it gets in the cheap WorkContainer.
  # WITHOUT this, when the preview cluster is up `agent_container/1`
  # prefers the compose `workspace` service — which had no home mount,
  # so gh/claude auth silently vanished (the "no GH_TOKEN here" bug).
  #
  # Only the `workspace` service gets the identity. App services (`dev`,
  # db, redis…) are cattle — they must NOT see the operator's personal
  # tokens. Env (tokens) is NOT injected via compose `environment:`;
  # it lives as files in the home volume (`~/.loopyard/env`, sourced by
  # `~/.profile`), exactly like WorkContainer. We only set `HOME` + the
  # mount here; `Compose.up/2` runs `Env.sync_home/1` first.
  defp inject_identity_home(compose) do
    case get_in(compose, ["services", "workspace"]) do
      svc when is_map(svc) ->
        identity = Loopyard.Workstation.current()
        home_volume = Loopyard.Workstation.home_volume(identity)
        home_path = "/home/#{identity}"

        svc =
          svc
          |> add_volume_mount("#{home_volume}:#{home_path}")
          |> put_env("HOME", home_path)

        compose
        |> put_in(["services", "workspace"], svc)
        |> ensure_external_volume(home_volume)

      _ ->
        compose
    end
  end

  defp add_volume_mount(svc, mount) do
    volumes = Map.get(svc, "volumes", []) || []
    Map.put(svc, "volumes", volumes ++ [mount])
  end

  # Compose `environment:` is either a list ("K=V") or a map (%{"K" => "V"}).
  # Preserve whichever shape the agent wrote.
  defp put_env(svc, key, value) do
    case Map.get(svc, "environment") do
      env when is_list(env) ->
        env = Enum.reject(env, &String.starts_with?(to_string(&1), "#{key}="))
        Map.put(svc, "environment", env ++ ["#{key}=#{value}"])

      env when is_map(env) ->
        Map.put(svc, "environment", Map.put(env, key, value))

      _ ->
        Map.put(svc, "environment", ["#{key}=#{value}"])
    end
  end

  defp ensure_external_volume(compose, volume_name) do
    volumes = Map.get(compose, "volumes", %{}) || %{}
    volumes = Map.put_new(volumes, volume_name, %{"external" => true})
    Map.put(compose, "volumes", volumes)
  end

  @doc """
  Reject compose files that mount host paths into containers.

  Agents run in their workspace container (with /workspace from a named
  Docker volume). Allowing `- /etc:/host/etc` or `type: bind` would punch
  straight through the workspace boundary — the whole point of the
  container sandbox is that agents CAN'T reach the host filesystem.

  Named volumes (including the workspace code volume) are fine; host
  paths are not. We parse short-form (`src:dst[:mode]`) and long-form
  (`%{"type" => ...}`) volume entries, plus top-level volume declarations
  with `driver_opts.device`.

  Returns `:ok` or `{:error, reason}`.
  """
  def validate_no_host_mounts(compose) when is_map(compose) do
    with :ok <- validate_service_volumes(compose),
         :ok <- validate_top_level_volumes(compose),
         :ok <- Loopyard.Compose.HostEscape.validate(compose),
         :ok <- validate_service_ports(compose),
         :ok <- validate_networks(compose) do
      :ok
    end
  end

  # Published ports: agents must NOT pin a specific host port.
  # Loopyard allocates host ports dynamically and remembers the
  # assignment across restarts (sticky ports). A pinned host port
  # invites collisions between workspaces ("I want 3000" × N agents),
  # and could be used to squat on a port another workspace is already
  # using. We accept only container-side specifications and add the
  # loopback binding ourselves in `pin_port/2`.
  defp validate_service_ports(compose) do
    services = Map.get(compose, "services", %{}) || %{}

    Enum.reduce_while(services, :ok, fn {name, svc}, _acc ->
      ports = (is_map(svc) && Map.get(svc, "ports")) || []

      case check_port_entries(name, ports) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp check_port_entries(_name, ports) when not is_list(ports), do: :ok

  defp check_port_entries(name, ports) do
    Enum.reduce_while(ports, :ok, fn entry, _acc ->
      case check_port(name, entry) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  # Accept:
  #   - `"3000"` or `3000` — container port, we pick the host port
  # Reject:
  #   - `"8080:3000"` — host port pinned
  #   - `"127.0.0.1:8080:3000"` — ditto, with explicit host IP
  #   - `%{"published" => _}` long form
  defp check_port(_name, n) when is_integer(n), do: :ok

  defp check_port(name, entry) when is_binary(entry) do
    case String.split(entry, ":") do
      [_container] ->
        :ok

      _ ->
        {:error,
         "service #{name}: host port pin is not allowed (#{inspect(entry)}).\n\n" <>
           "Why: Loopyard assigns host ports dynamically and keeps them sticky " <>
           "across restarts. Pinning invites collisions between workspaces and " <>
           "lets one workspace squat on another's port.\n\n" <>
           "Fix: list only the container port — `\"3000\"` instead of `\"8080:3000\"`. " <>
           "Loopyard will pick a free host port and reuse the same one on restart."}
    end
  end

  defp check_port(name, %{"published" => _} = entry) do
    {:error,
     "service #{name}: host port pin is not allowed (#{inspect(entry)}). " <>
       "Use the short form with only a container port (e.g. `\"3000\"`)."}
  end

  defp check_port(_name, entry) when is_map(entry), do: :ok

  defp check_port(name, entry),
    do: {:error, "service #{name}: invalid port entry #{inspect(entry)}"}

  # Top-level and per-service `networks:` must not reference external
  # networks — that would attach the container to a Docker network
  # Loopyard doesn't own, breaking the per-workspace isolation that
  # `docker compose -p <project>` gives us by default.
  defp validate_networks(compose) do
    with :ok <- validate_top_level_networks(compose),
         :ok <- validate_service_networks(compose) do
      :ok
    end
  end

  defp validate_top_level_networks(compose) do
    networks = Map.get(compose, "networks", %{}) || %{}

    Enum.reduce_while(networks, :ok, fn {name, spec}, _acc ->
      cond do
        is_map(spec) and spec["external"] == true ->
          {:halt,
           {:error,
            "top-level network #{inspect(name)}: `external: true` is not allowed. " <>
              "Joining a network Loopyard doesn't own lets this service reach " <>
              "containers from other workspaces. Drop the `external` flag or " <>
              "remove the network entry — the default compose network is already " <>
              "isolated per workspace."}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp validate_service_networks(compose) do
    services = Map.get(compose, "services", %{}) || %{}

    Enum.reduce_while(services, :ok, fn {name, svc}, _acc ->
      case check_service_networks(name, (is_map(svc) && svc["networks"]) || nil) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp check_service_networks(_name, nil), do: :ok
  defp check_service_networks(_name, networks) when networks in [%{}, []], do: :ok

  defp check_service_networks(name, networks) when is_map(networks) do
    if Enum.any?(networks, fn {_n, cfg} -> is_map(cfg) and cfg["external"] == true end) do
      {:error,
       "service #{name}: a joined network declares `external: true`. " <>
         "Agents may not attach services to networks Loopyard doesn't own."}
    else
      :ok
    end
  end

  defp check_service_networks(_name, networks) when is_list(networks), do: :ok
  defp check_service_networks(_name, _), do: :ok

  defp validate_service_volumes(compose) do
    services = Map.get(compose, "services", %{}) || %{}

    Enum.reduce_while(services, :ok, fn {svc_name, svc}, _acc ->
      volumes = (is_map(svc) && Map.get(svc, "volumes")) || []

      case check_service_volume_entries(svc_name, volumes) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp check_service_volume_entries(_svc_name, volumes) when not is_list(volumes), do: :ok

  defp check_service_volume_entries(svc_name, volumes) do
    Enum.reduce_while(volumes, :ok, fn entry, _acc ->
      case check_service_volume(svc_name, entry) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  # Short form: "source:target[:mode]". Source that looks like a host
  # path (starts with /, ., ~) is rejected. A bare name is a named
  # volume — allowed. The ${CODE_VOLUME} placeholder is resolved later
  # to a bare volume name, so it's also allowed here.
  defp check_service_volume(svc_name, entry) when is_binary(entry) do
    source =
      case String.split(entry, ":", parts: 2) do
        [src, _rest] -> src
        [src] -> src
      end

    cond do
      source == "" ->
        {:error, "service #{svc_name}: empty volume source"}

      host_path?(source) ->
        {:error,
         "service #{svc_name}: host bind mount is not allowed (#{inspect(entry)}).\n\n" <>
           "Why: the workspace runs in its own Docker container — there is no host " <>
           "filesystem to mount. Bind mounts would also cross into other workspaces.\n\n" <>
           "Fix: replace the bind mount with a named volume. If the container needs " <>
           "seed files (config, fixtures, the app source), write them into the volume " <>
           "via `write_file` (paths under `/workspace/...`) BEFORE running " <>
           "`docker_compose up`, then mount the named volume instead. The source tree " <>
           "is already in the `${CODE_VOLUME}` volume mounted at /workspace."}

      true ->
        :ok
    end
  end

  # Long form: %{"type" => "bind" | "volume" | "tmpfs", ...}
  defp check_service_volume(svc_name, %{"type" => type} = entry) do
    cond do
      type == "bind" ->
        {:error,
         "service #{svc_name}: `type: bind` is not allowed (#{inspect(entry)}). " <>
           "Use named volumes only."}

      type in ["volume", "tmpfs"] ->
        :ok

      true ->
        {:error, "service #{svc_name}: unsupported volume type #{inspect(type)}"}
    end
  end

  defp check_service_volume(_svc_name, entry) when is_map(entry), do: :ok

  defp check_service_volume(svc_name, entry),
    do: {:error, "service #{svc_name}: invalid volume entry #{inspect(entry)}"}

  # Top-level `volumes:` declarations. Allow `external: true`, empty map,
  # or driver configs that don't point a named volume at a host path via
  # `driver_opts.device`.
  defp validate_top_level_volumes(compose) do
    volumes = Map.get(compose, "volumes", %{}) || %{}

    Enum.reduce_while(volumes, :ok, fn {name, spec}, _acc ->
      case check_top_level_volume(name, spec) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp check_top_level_volume(_name, nil), do: :ok
  defp check_top_level_volume(_name, spec) when spec == %{}, do: :ok

  defp check_top_level_volume(name, spec) when is_map(spec) do
    device =
      case Map.get(spec, "driver_opts") do
        %{"device" => d} -> d
        _ -> nil
      end

    if is_binary(device) and host_path?(device) do
      {:error,
       "top-level volume #{inspect(name)}: driver_opts.device points at a host path " <>
         "(#{inspect(device)}). Host-backed volumes are not allowed."}
    else
      :ok
    end
  end

  defp check_top_level_volume(_name, _), do: :ok

  defp host_path?(s) when is_binary(s) do
    String.starts_with?(s, "/") or
      String.starts_with?(s, "./") or
      String.starts_with?(s, "../") or
      s == "." or s == ".." or
      String.starts_with?(s, "~")
  end

  defp host_path?(_), do: false

  defp parse_compose(content) do
    case Jason.decode(content) do
      {:ok, compose} ->
        {:ok, compose}

      {:error, _} ->
        case YamlElixir.read_from_string(content) do
          {:ok, compose} -> {:ok, compose}
          {:error, reason} -> {:error, "Invalid compose file: #{inspect(reason)}"}
        end
    end
  end

  defp process_services(compose, code_volume, workspace_id) do
    update_in(compose, ["services"], fn services ->
      services
      |> Enum.map(fn {name, svc} ->
        svc = update_volumes_placeholder(svc, code_volume)
        svc = assign_registry_ports(svc, workspace_id, name)
        {name, svc}
      end)
      |> Map.new()
    end)
  end

  defp ensure_code_volume(compose, code_volume) do
    volumes = Map.get(compose, "volumes", %{}) || %{}
    volumes = Map.put(volumes, code_volume, %{"external" => true})
    Map.put(compose, "volumes", volumes)
  end

  # FORK SAFETY: rewrite any top-level external volume whose `name:` points at
  # *another* workspace's code volume (`loopyard-<id>-code`) to THIS workspace's
  # code volume. An agent that hardcoded the literal name instead of
  # ${CODE_VOLUME} (e.g. `name: loopyard-a6e9da50-code`) would otherwise have the
  # FORK mount and mutate the SOURCE's code — silent cross-workspace corruption.
  # We only touch names that match the loopyard code-volume shape, so unrelated
  # named volumes (postgres-data, etc.) are left alone.
  # ANY loopyard code-volume name that isn't ours becomes ours. Used on both
  # top-level `name:` and SERVICE MOUNTS — the mount was the gap: normalizing
  # only the declaration left `- loopyard-<source>-code:/workspace` in a
  # service, so a fork mounted and mutated the SOURCE's code. That is the exact
  # silent cross-workspace corruption this is here to prevent.
  @code_volume_ref ~r/loopyard-[A-Za-z0-9_-]+-code/

  defp resolve_foreign_code_volume(value, code_volume) do
    String.replace(value, @code_volume_ref, code_volume)
  end

  defp normalize_code_volume_names(compose, code_volume) do
    case Map.get(compose, "volumes") do
      volumes when is_map(volumes) ->
        fixed =
          Map.new(volumes, fn
            {k, %{"name" => name} = spec} when is_binary(name) ->
              # The setup guide's own example writes `name: ${CODE_VOLUME}`, and
              # nothing resolved it here — only service mounts were substituted,
              # so a compose following the documented form reached Docker with a
              # literal "${CODE_VOLUME}" and failed to start.
              resolved =
                name
                |> String.replace("${CODE_VOLUME}", code_volume)
                |> resolve_foreign_code_volume(code_volume)

              {k, Map.put(spec, "name", resolved)}

            {k, v} ->
              {k, v}
          end)

        Map.put(compose, "volumes", fixed)

      _ ->
        compose
    end
  end

  defp update_volumes_placeholder(svc, code_volume) when is_map(svc) do
    case svc["volumes"] do
      volumes when is_list(volumes) ->
        updated =
          Enum.map(volumes, fn
            vol when is_binary(vol) ->
              vol
              |> String.replace("${CODE_VOLUME}", code_volume)
              |> resolve_foreign_code_volume(code_volume)

            vol ->
              vol
          end)

        Map.put(svc, "volumes", updated)

      _ ->
        svc
    end
  end

  defp update_volumes_placeholder(svc, _), do: svc

  # Replace each service's `ports:` list with
  # `"127.0.0.1:<registry_port>:<container_port>"` entries, asking
  # `Loopyard.PortRegistry` for the host-side port. The registry is
  # sticky per `{workspace_id, service, container_port}` so the same
  # URL works across restarts.
  #
  # Loopback-only binding keeps ports off the LAN by default. Explicit
  # exposure (v2) is a separate TCP proxy that fronts the loopback
  # port without rewriting compose.
  defp assign_registry_ports(svc, workspace_id, service_name) when is_map(svc) do
    case svc["ports"] do
      ports when is_list(ports) ->
        assigned =
          Enum.map(ports, &emit_port(&1, workspace_id, service_name))

        Map.put(svc, "ports", assigned)

      _ ->
        svc
    end
  end

  defp assign_registry_ports(svc, _workspace_id, _service_name), do: svc

  defp emit_port(port_spec, workspace_id, service_name) when is_binary(port_spec) do
    container_port = extract_container_port(port_spec)

    # Register the user-facing port (sticky). Docker gets ephemeral —
    # our proxy will own the user-facing port.
    case Loopyard.PortRegistry.assign(workspace_id, service_name, container_port) do
      {:ok, _host_port} ->
        "127.0.0.1::#{container_port}"

      {:error, :port_pool_exhausted} ->
        "127.0.0.1::#{container_port}"
    end
  end

  defp emit_port(port_spec, workspace_id, service_name) when is_integer(port_spec) do
    emit_port(to_string(port_spec), workspace_id, service_name)
  end

  # Extract the container port number from various formats
  defp extract_container_port(port_spec) do
    port_str =
      case String.split(port_spec, ":") do
        [_host, container] -> container
        [container] -> container
        [_ip, _host, container] -> container
      end

    # Strip protocol suffix like /tcp
    port_str |> String.split("/") |> hd() |> String.to_integer()
  end

  @doc "Path to the compose file."
  def compose_path(project_dir),
    do: Path.join([project_dir, ".loopyard", "workspace", "docker-compose.yml"])

  @doc "Project name for compose (used for container naming)."
  def project_name(workspace_id), do: "#{Loopyard.Docker.prefix()}#{workspace_id}"

  @doc "Run a docker compose command. Uses `docker compose` (v2 plugin) if available, otherwise `docker-compose` (standalone)."
  def compose(project_dir, workspace_id, args, opts \\ []) do
    compose_file = compose_path(project_dir)
    project = project_name(workspace_id)
    timeout = Keyword.get(opts, :timeout, 120_000)

    base_args = ["-f", compose_file, "-p", project] ++ args

    if docker_compose_v2?() do
      Loopyard.Docker.docker(["compose" | base_args], timeout: timeout)
    else
      docker_compose(base_args, timeout)
    end
  end

  @doc "Run a docker compose command with pre-built args (includes -f and -p flags)."
  def compose_cmd(args, timeout \\ 120_000) do
    if docker_compose_v2?() do
      Loopyard.Docker.docker(["compose" | args], timeout: timeout)
    else
      docker_compose(args, timeout)
    end
  end

  defp docker_compose(args, timeout) do
    cond do
      # Same contract as Docker.docker/2's gate — keeps the default test
      # suite off the daemon entirely.
      not Application.get_env(:loopyard, :docker_enabled, true) ->
        {:error, "docker disabled in this environment"}

      # No compose binary at all. This is the fresh Colima / OrbStack /
      # Docker Engine case: no `docker compose` v2 plugin AND no
      # `docker-compose`. `System.cmd` on a missing binary raises `:enoent`
      # INSIDE the linked Task, which propagates and crashes the caller
      # (the ServiceManager) — so check for it up front and return an error
      # tuple the caller can surface instead.
      is_nil(System.find_executable("docker-compose")) ->
        {:error,
         "Docker Compose is not installed. Loopyard needs it to run project " <>
           "stacks — install Docker Desktop, or the `docker compose` plugin / " <>
           "`docker-compose` binary for Colima, OrbStack, or Docker Engine."}

      true ->
        task = Task.async(fn -> System.cmd("docker-compose", args, stderr_to_stdout: true) end)

        case Task.yield(task, timeout) || Task.shutdown(task) do
          {:ok, {output, 0}} -> {:ok, output}
          {:ok, {output, _}} -> {:error, output}
          _ -> {:error, "docker-compose timed out"}
        end
    end
  end

  @doc "Start all services."
  def up(project_dir, workspace_id) do
    :telemetry.span([:loopyard, :compose, :up], %{workspace_id: workspace_id}, fn ->
      # Materialize the operator's identity env (tokens) into the home
      # volume's ~/.profile BEFORE the cluster boots, so the `workspace`
      # service (which mounts that volume — see inject_identity_home/1)
      # has gh/claude/fly creds the moment an agent execs into it. Stage
      # the operator CLIs (gh/fly) into the volume too — the project's app
      # image doesn't ship them.
      identity = Loopyard.Workstation.current()
      _ = Loopyard.Workstation.Env.sync_home(identity)
      _ = Loopyard.Workstation.Env.stage_tools(identity)
      _ = Loopyard.Workstation.Env.sync_claude(identity)
      _ = Loopyard.Workstation.Env.trust_projects(identity)

      result = compose(project_dir, workspace_id, ["up", "-d", "--build"], timeout: 600_000)
      {result, %{}}
    end)
  end

  @doc "Check if `docker compose` v2 plugin is available. Result is cached."
  def docker_compose_v2? do
    case :persistent_term.get(:docker_compose_v2, :unchecked) do
      :unchecked ->
        result =
          case Loopyard.Docker.docker(["compose", "version"]) do
            {:ok, output} -> String.contains?(output, "Docker Compose")
            _ -> false
          end

        :persistent_term.put(:docker_compose_v2, result)
        result

      cached ->
        cached
    end
  rescue
    _ -> false
  end

  @doc "Stop all services."
  def down(project_dir, workspace_id) do
    :telemetry.span([:loopyard, :compose, :down], %{workspace_id: workspace_id}, fn ->
      result = compose(project_dir, workspace_id, ["down"], timeout: 30_000)
      {result, %{}}
    end)
  end

  @doc "Stop all services and remove volumes (clean slate)."
  def down_volumes(project_dir, workspace_id) do
    compose(project_dir, workspace_id, ["down", "-v"], timeout: 30_000)
  end

  @doc "Get running service names."
  def ps(project_dir, workspace_id) do
    case compose(project_dir, workspace_id, [
           "ps",
           "--format",
           "{{.Service}}\t{{.State}}\t{{.Ports}}"
         ]) do
      {:ok, output} ->
        services =
          output
          |> String.trim()
          |> String.split("\n", trim: true)
          |> Enum.map(fn line ->
            case String.split(line, "\t") do
              [name, state | rest] ->
                ports = Enum.at(rest, 0, "")
                %{name: name, state: state, ports: parse_compose_ports(ports)}

              _ ->
                nil
            end
          end)
          |> Enum.reject(&is_nil/1)

        {:ok, services}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Exec a command in a compose service."
  def exec(project_dir, workspace_id, service, command, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 120_000)

    compose(project_dir, workspace_id, ["exec", "-T", service, "sh", "-c", command],
      timeout: timeout
    )
  end

  @doc "Get logs for a compose service."
  def logs(project_dir, workspace_id, service, opts \\ []) do
    tail = Keyword.get(opts, :tail, 200)
    compose(project_dir, workspace_id, ["logs", "--tail", "#{tail}", "--no-log-prefix", service])
  end

  @doc "Get the container name for a compose service."
  def container_name(project_dir, workspace_id, service) do
    case compose(project_dir, workspace_id, ["ps", "-q", service]) do
      {:ok, output} ->
        id = String.trim(output)

        if id != "" do
          case Loopyard.Docker.docker(["inspect", "--format", "{{.Name}}", id]) do
            {:ok, name} -> String.trim(name) |> String.trim_leading("/")
            _ -> nil
          end
        else
          nil
        end

      _ ->
        nil
    end
  end

  # --- Private ---

  defp parse_compose_ports(""), do: %{}

  defp parse_compose_ports(ports_str) do
    # Format: "0.0.0.0:32871->3000/tcp, :::32871->3000/tcp"
    Regex.scan(~r/(?:\d+\.){3}\d+:(\d+)->(\d+)/, ports_str)
    |> Map.new(fn [_, host_port, container_port] -> {container_port, host_port} end)
  end
end
