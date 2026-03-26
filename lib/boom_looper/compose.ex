defmodule BoomLooper.Compose do
  @moduledoc """
  Generates and manages docker-compose.yml files for workspaces.
  Translates workspace config into compose services.
  """

  alias BoomLooper.Workspace

  @doc "Generate docker-compose.yml content from workspace config."
  def generate(%Workspace{} = ws, project_dir, workspace_id) do
    services = %{}

    # Write Dockerfile to .boomlooper/workspace/ so compose can reference it
    dockerfile_path = Path.join([project_dir, ".boomlooper", "workspace", "Dockerfile"])
    if ws.dockerfile, do: write_unless_symlink(dockerfile_path, ws.dockerfile)

    # Workspace container — always running, agents exec here
    services = if ws.dockerfile do
      Map.put(services, "workspace", %{
        "build" => %{"context" => project_dir, "dockerfile" => ".boomlooper/workspace/Dockerfile"},
        "command" => "sleep infinity",
        "volumes" => [
          "#{project_dir}:/workspace",
          "cache-#{workspace_id}:/root/.cache"
        ],
        "working_dir" => "/workspace",
        "environment" => env_list(ws.env_vars)
      })
    else
      services
    end

    # Dev container — runs the dev command from workspace image
    services = Enum.reduce(ws.processes, services, fn p, acc ->
      svc = %{
        "build" => %{"context" => project_dir, "dockerfile" => ".boomlooper/workspace/Dockerfile"},
        "command" => p.command,
        "volumes" => [
          "#{project_dir}:/workspace",
          "cache-#{workspace_id}:/root/.cache"
        ],
        "working_dir" => "/workspace",
        "environment" => env_list(ws.env_vars)
      }

      # Add ports — always use dynamic host port allocation to avoid conflicts.
      # "3001:3000" becomes "3000" (Docker picks a free host port).
      svc = case p[:ports] do
        ports when is_list(ports) and ports != [] ->
          Map.put(svc, "ports", Enum.map(ports, &container_port_only/1))
        _ ->
          svc
      end

      Map.put(acc, p.name, svc)
    end)

    # Stock services — postgres, redis, etc.
    services = Enum.reduce(ws.services, services, fn s, acc ->
      svc = %{"image" => s.image}

      svc = if s[:env] && s.env != %{},
        do: Map.put(svc, "environment", env_list(s.env)),
        else: svc

      svc = if s[:ports] && s.ports != [],
        do: Map.put(svc, "ports", Enum.map(s.ports, fn p -> container_port_only(to_string(p)) end)),
        else: svc

      svc = if s[:volumes] && s.volumes != [],
        do: Map.put(svc, "volumes", Enum.map(s.volumes, fn v ->
          String.replace(v, "{data}", "#{s.name}-data-#{workspace_id}")
        end)),
        else: svc

      Map.put(acc, s.name, svc)
    end)

    # Volumes
    volumes = %{"cache-#{workspace_id}" => nil}
    volumes = Enum.reduce(ws.services, volumes, fn s, acc ->
      Enum.reduce(s[:volumes] || [], acc, fn v, a ->
        if String.contains?(v, "{data}") do
          vol_name = "#{s.name}-data-#{workspace_id}"
          Map.put(a, vol_name, nil)
        else
          a
        end
      end)
    end)

    compose = %{"services" => services}
    compose = if volumes != %{}, do: Map.put(compose, "volumes", volumes), else: compose

    Jason.encode!(compose, pretty: true)
  end

  @doc "Write docker-compose.yml to the .boomlooper/workspace directory."
  def write(project_dir, workspace_id) do
    case Workspace.load(project_dir) do
      {:ok, ws} ->
        content = generate(ws, project_dir, workspace_id)
        compose_path = compose_path(project_dir)
        write_unless_symlink(compose_path, content)
        {:ok, compose_path}

      other ->
        other
    end
  end

  @doc "Path to the compose file."
  def compose_path(project_dir), do: Path.join([project_dir, ".boomlooper", "workspace", "docker-compose.yml"])

  @doc "Project name for compose (used for container naming)."
  def project_name(workspace_id), do: "bl-#{workspace_id}"

  @doc "Run a docker compose command. Tries `docker compose` (v2 plugin) first, falls back to `docker-compose` (standalone)."
  def compose(project_dir, workspace_id, args, opts \\ []) do
    compose_file = compose_path(project_dir)
    project = project_name(workspace_id)
    timeout = Keyword.get(opts, :timeout, 120_000)

    base_args = ["-f", compose_file, "-p", project] ++ args

    # Try docker compose v2 (plugin) first
    case BoomLooper.Docker.docker(["compose" | base_args], timeout: timeout) do
      {:error, output} when is_binary(output) and byte_size(output) > 0 ->
        if String.contains?(output, "unknown shorthand flag") || String.contains?(output, "is not a docker command") do
          # Fall back to standalone docker-compose
          docker_compose(base_args, timeout)
        else
          {:error, output}
        end

      other ->
        other
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
    compose(project_dir, workspace_id, ["up", "-d", "--build"], timeout: 600_000)
  end

  @doc """
  Start all services with streaming output. Calls `callback` with each chunk of output.
  Returns {:ok, full_output} or {:error, full_output} when done.
  """
  def up_stream(project_dir, workspace_id, callback) when is_function(callback, 1) do
    compose_file = compose_path(project_dir)
    project = project_name(workspace_id)

    base_args = ["-f", compose_file, "-p", project, "up", "-d", "--build"]

    # Try docker compose v2 (plugin) first, fall back to standalone docker-compose
    case stream_compose(["compose" | base_args], callback) do
      {:error, output} when is_binary(output) ->
        if String.contains?(output, "unknown shorthand flag") || String.contains?(output, "is not a docker command") do
          stream_docker_compose(base_args, callback)
        else
          {:error, output}
        end

      other ->
        other
    end
  end

  defp stream_compose(args, callback) do
    docker_path = System.find_executable("docker")

    unless docker_path do
      {:error, "docker not found"}
    else
      port = Port.open(
        {:spawn_executable, docker_path},
        [:binary, :exit_status, :stderr_to_stdout, {:args, args}]
      )

      collect_port_output(port, callback, "", 600_000)
    end
  end

  defp stream_docker_compose(args, callback) do
    dc_path = System.find_executable("docker-compose")

    unless dc_path do
      {:error, "docker-compose not found"}
    else
      port = Port.open(
        {:spawn_executable, dc_path},
        [:binary, :exit_status, :stderr_to_stdout, {:args, args}]
      )

      collect_port_output(port, callback, "", 600_000)
    end
  end

  @doc false
  def collect_port_output(port, callback, acc, timeout) do
    receive do
      {^port, {:data, data}} ->
        callback.(data)
        new_acc = acc <> data

        # Fail fast on known fatal errors
        cond do
          String.contains?(new_acc, "no matching manifest for linux/arm64") ->
            Port.close(port)
            {:error, :arm64_unsupported, new_acc}

          true ->
            collect_port_output(port, callback, new_acc, timeout)
        end

      {^port, {:exit_status, 0}} ->
        {:ok, acc}

      {^port, {:exit_status, _code}} ->
        {:error, acc}
    after
      timeout ->
        Port.close(port)
        {:error, acc <> "\n(timed out)"}
    end
  end

  @doc "Stop all services."
  def down(project_dir, workspace_id) do
    compose(project_dir, workspace_id, ["down"], timeout: 30_000)
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

  defp write_unless_symlink(path, content) do
    case File.lstat(path) do
      {:ok, %{type: :symlink}} -> :ok
      _ ->
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, content)
    end
  end

  # Strip host port from a port mapping, keeping only the container port.
  # "3001:3000" -> "3000", "3000" -> "3000", "3000/tcp" -> "3000/tcp"
  defp container_port_only(port_spec) when is_binary(port_spec) do
    case String.split(port_spec, ":") do
      [_host, container] -> container
      [container] -> container
      [_ip, _host, container] -> container
    end
  end

  defp env_list(env) when is_map(env) do
    Enum.map(env, fn {k, v} -> "#{k}=#{v}" end)
  end

  defp env_list(_), do: []

  defp parse_compose_ports(""), do: %{}
  defp parse_compose_ports(ports_str) do
    # Format: "0.0.0.0:32871->3000/tcp, :::32871->3000/tcp"
    Regex.scan(~r/(?:\d+\.){3}\d+:(\d+)->(\d+)/, ports_str)
    |> Map.new(fn [_, host_port, container_port] -> {container_port, host_port} end)
  end

end
