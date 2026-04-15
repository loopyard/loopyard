defmodule BoomLooper.Compose do
  @moduledoc """
  Docker Compose operations for workspaces.

  Agents write docker-compose.yml directly via boom-looper-container tools.
  This module processes those files and runs compose commands.
  """

  alias BoomLooper.Workspace

  @doc """
  Process an agent-written docker-compose.yml with minimal fixups.
  Agents write standard compose syntax. We:
  1. Replace ${CODE_VOLUME} placeholder with actual volume name
  2. Ensure the code volume is declared as external
  3. Pin host ports from previous run (sticky ports across restarts)

  Options:
    * `:port_map` — `%{"service_name" => %{container_port => host_port}}` from the
      previous run. If a service had port 33870→3000, we pin "33870:3000" so the
      URL stays stable across restarts. If omitted, ports are dynamically allocated.
  """
  def process_agent_compose(compose_content, workspace_id, opts \\ []) do
    code_volume = Workspace.volume_name_for(workspace_id)
    port_map = Keyword.get(opts, :port_map, %{})

    case parse_compose(compose_content) do
      {:ok, compose} ->
        with :ok <- validate_no_host_mounts(compose) do
          compose = process_services(compose, code_volume, port_map)
          compose = ensure_code_volume(compose, code_volume)
          {:ok, Jason.encode!(compose, pretty: true)}
        end

      {:error, reason} ->
        {:error, reason}
    end
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
         :ok <- validate_service_host_escapes(compose),
         :ok <- validate_service_ports(compose),
         :ok <- validate_networks(compose) do
      :ok
    end
  end

  # Published ports: agents must NOT pin a specific host port.
  # BoomLooper allocates host ports dynamically and remembers the
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
           "Why: BoomLooper assigns host ports dynamically and keeps them sticky " <>
           "across restarts. Pinning invites collisions between workspaces and " <>
           "lets one workspace squat on another's port.\n\n" <>
           "Fix: list only the container port — `\"3000\"` instead of `\"8080:3000\"`. " <>
           "BoomLooper will pick a free host port and reuse the same one on restart."}
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
  # BoomLooper doesn't own, breaking the per-workspace isolation that
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
              "Joining a network BoomLooper doesn't own lets this service reach " <>
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
         "Agents may not attach services to networks BoomLooper doesn't own."}
    else
      :ok
    end
  end

  defp check_service_networks(_name, networks) when is_list(networks), do: :ok
  defp check_service_networks(_name, _), do: :ok

  # Block the other common ways a compose service can punch through the
  # container boundary: privileged mode, sharing host namespaces, direct
  # device access. These are all runtime grants that defeat the sandbox
  # just as thoroughly as a bind mount — no point blocking one and not
  # the others.
  defp validate_service_host_escapes(compose) do
    services = Map.get(compose, "services", %{}) || %{}

    Enum.reduce_while(services, :ok, fn {name, svc}, _acc ->
      case check_host_escape(name, svc) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp check_host_escape(name, svc) when is_map(svc) do
    cond do
      svc["privileged"] == true ->
        {:error,
         "service #{name}: `privileged: true` is not allowed. " <>
           "Privileged containers can remount the host filesystem and " <>
           "reach other workspaces. Drop the key, or if you genuinely " <>
           "need a capability use `cap_add: [SPECIFIC_CAP]` instead."}

      svc["network_mode"] == "host" ->
        {:error,
         "service #{name}: `network_mode: host` is not allowed. " <>
           "Host networking lets this service bind to the host's ports " <>
           "(clashing with other workspaces) and reach host services " <>
           "directly. Use the default bridge network; expose ports via " <>
           "the `ports:` key so BoomLooper can route them."}

      svc["pid"] == "host" ->
        {:error,
         "service #{name}: `pid: host` is not allowed — it exposes every " <>
           "host process (including other workspaces' containers) to this " <>
           "service. Remove the key."}

      svc["ipc"] == "host" ->
        {:error,
         "service #{name}: `ipc: host` is not allowed — it shares the host's " <>
           "IPC namespace across workspaces. Remove the key."}

      svc["userns_mode"] == "host" ->
        {:error,
         "service #{name}: `userns_mode: host` is not allowed — it disables " <>
           "user-namespace isolation. Remove the key."}

      is_list(svc["devices"]) and svc["devices"] != [] ->
        {:error,
         "service #{name}: `devices:` is not allowed (#{inspect(svc["devices"])}). " <>
           "Direct host device access breaks the workspace boundary. Remove " <>
           "the key or find a userspace alternative."}

      true ->
        :ok
    end
  end

  defp check_host_escape(_name, _), do: :ok

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
      {:ok, compose} -> {:ok, compose}
      {:error, _} ->
        case YamlElixir.read_from_string(content) do
          {:ok, compose} -> {:ok, compose}
          {:error, reason} -> {:error, "Invalid compose file: #{inspect(reason)}"}
        end
    end
  end

  defp process_services(compose, code_volume, port_map) do
    update_in(compose, ["services"], fn services ->
      services
      |> Enum.map(fn {name, svc} ->
        svc = update_volumes_placeholder(svc, code_volume)
        svc = pin_or_strip_ports(svc, Map.get(port_map, name, %{}))
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

  defp update_volumes_placeholder(svc, code_volume) when is_map(svc) do
    case svc["volumes"] do
      volumes when is_list(volumes) ->
        updated = Enum.map(volumes, fn
          vol when is_binary(vol) ->
            String.replace(vol, "${CODE_VOLUME}", code_volume)
          vol -> vol
        end)
        Map.put(svc, "volumes", updated)
      _ -> svc
    end
  end
  defp update_volumes_placeholder(svc, _), do: svc

  # Pin previously-assigned host ports so URLs survive restarts.
  # Falls back to dynamic allocation if no previous mapping exists.
  defp pin_or_strip_ports(svc, prev_ports) when is_map(svc) do
    case svc["ports"] do
      ports when is_list(ports) ->
        pinned = Enum.map(ports, &pin_port(&1, prev_ports))
        Map.put(svc, "ports", pinned)
      _ -> svc
    end
  end
  defp pin_or_strip_ports(svc, _), do: svc

  # If we have a previous host port for this container port, pin it.
  # Otherwise strip to container-only for dynamic allocation.
  #
  # All emitted ports bind to 127.0.0.1 instead of the default 0.0.0.0.
  # Loopback-only means:
  #   1. Other workspaces' containers can't reach this service via the
  #      Docker host gateway — the whole point of per-workspace network
  #      isolation is defeated if ports are reachable at `<docker-host>:<port>`.
  #   2. Machines on the LAN can't hit dev servers without authenticating
  #      through BoomLooper. Local multiplayer goes via the Phoenix app;
  #      agent containers are not publicly exposed.
  defp pin_port(port_spec, prev_ports) when is_binary(port_spec) do
    container_port = extract_container_port(port_spec)

    case Map.get(prev_ports, container_port) || Map.get(prev_ports, to_string(container_port)) do
      nil -> "127.0.0.1::#{container_port}"
      host_port -> "127.0.0.1:#{host_port}:#{container_port}"
    end
  end
  defp pin_port(port_spec, prev_ports) when is_integer(port_spec) do
    pin_port(to_string(port_spec), prev_ports)
  end

  # Extract the container port number from various formats
  defp extract_container_port(port_spec) do
    port_str = case String.split(port_spec, ":") do
      [_host, container] -> container
      [container] -> container
      [_ip, _host, container] -> container
    end
    # Strip protocol suffix like /tcp
    port_str |> String.split("/") |> hd() |> String.to_integer()
  end

  @doc """
  Capture the current port assignments for all services in a workspace.
  Returns `%{"dev" => %{3000 => 33870}, "postgres" => %{5432 => 33871}}`.
  Used to pin ports across restarts.
  """
  def capture_port_map(workspace_id) do
    project_name = project_name(workspace_id)

    BoomLooper.Docker.Observer.containers_for(workspace_id)
    |> Enum.reject(&(&1.name =~ ~r/-workspace-/))
    |> Map.new(fn container ->
      # Extract service name: "bl-abcd-dev-1" → "dev"
      service = container.name
        |> String.replace_prefix("#{project_name}-", "")
        |> String.replace_suffix("-1", "")

      {service, container.host_ports}
    end)
  end

  @doc "Path to the compose file."
  def compose_path(project_dir), do: Path.join([project_dir, ".boomlooper", "workspace", "docker-compose.yml"])

  @doc "Project name for compose (used for container naming)."
  def project_name(workspace_id), do: "bl-#{workspace_id}"

  @doc "Run a docker compose command. Uses `docker compose` (v2 plugin) if available, otherwise `docker-compose` (standalone)."
  def compose(project_dir, workspace_id, args, opts \\ []) do
    compose_file = compose_path(project_dir)
    project = project_name(workspace_id)
    timeout = Keyword.get(opts, :timeout, 120_000)

    base_args = ["-f", compose_file, "-p", project] ++ args

    if docker_compose_v2?() do
      BoomLooper.Docker.docker(["compose" | base_args], timeout: timeout)
    else
      docker_compose(base_args, timeout)
    end
  end

  @doc "Run a docker compose command with pre-built args (includes -f and -p flags)."
  def compose_cmd(args, timeout \\ 120_000) do
    if docker_compose_v2?() do
      BoomLooper.Docker.docker(["compose" | args], timeout: timeout)
    else
      docker_compose(args, timeout)
    end
  end

  defp docker_compose(args, timeout) do
    task = Task.async(fn ->
      System.cmd("docker-compose", args, stderr_to_stdout: true)
    end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, {output, 0}} -> {:ok, output}
      {:ok, {output, _}} -> {:error, output}
      nil -> {:error, "docker-compose timed out"}
    end
  end

  @doc "Start all services."
  def up(project_dir, workspace_id) do
    :telemetry.span([:boom_looper, :compose, :up], %{workspace_id: workspace_id}, fn ->
      result = compose(project_dir, workspace_id, ["up", "-d", "--build"], timeout: 600_000)
      {result, %{}}
    end)
  end

  @doc "Check if `docker compose` v2 plugin is available. Result is cached."
  def docker_compose_v2? do
    case :persistent_term.get(:docker_compose_v2, :unchecked) do
      :unchecked ->
        result =
          case BoomLooper.Docker.docker(["compose", "version"]) do
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
    :telemetry.span([:boom_looper, :compose, :down], %{workspace_id: workspace_id}, fn ->
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
    case compose(project_dir, workspace_id, ["ps", "--format", "{{.Service}}\t{{.State}}\t{{.Ports}}"]) do
      {:ok, output} ->
        services = output
        |> String.trim()
        |> String.split("\n", trim: true)
        |> Enum.map(fn line ->
          case String.split(line, "\t") do
            [name, state | rest] ->
              ports = Enum.at(rest, 0, "")
              %{name: name, state: state, ports: parse_compose_ports(ports)}
            _ -> nil
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
    compose(project_dir, workspace_id, ["exec", "-T", service, "sh", "-c", command], timeout: timeout)
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
          case BoomLooper.Docker.docker(["inspect", "--format", "{{.Name}}", id]) do
            {:ok, name} -> String.trim(name) |> String.trim_leading("/")
            _ -> nil
          end
        else
          nil
        end
      _ -> nil
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
