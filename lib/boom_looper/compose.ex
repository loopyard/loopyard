defmodule BoomLooper.Compose do
  @moduledoc """
  Generates and manages docker-compose.yml files for workspaces.
  Translates workspace config into compose services.
  """

  alias BoomLooper.Workspace

  @doc "Generate docker-compose.yml content from workspace config."
  def generate(%Workspace{} = ws, project_dir, workspace_id) do
    services = %{}

    # Workspace container — always running, agents exec here
    services = if ws.dockerfile do
      Map.put(services, "workspace", %{
        "build" => %{"context" => project_dir, "dockerfile_inline" => ws.dockerfile},
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
        "build" => %{"context" => project_dir, "dockerfile_inline" => ws.dockerfile || default_dockerfile()},
        "command" => p.command,
        "volumes" => [
          "#{project_dir}:/workspace",
          "cache-#{workspace_id}:/root/.cache"
        ],
        "working_dir" => "/workspace",
        "environment" => env_list(ws.env_vars)
      }

      # Add ports
      svc = case p[:ports] do
        ports when is_list(ports) and ports != [] ->
          Map.put(svc, "ports", ports)
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
        do: Map.put(svc, "ports", Enum.map(s.ports, &to_string/1)),
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

  @doc "Write docker-compose.yml to the .hive directory."
  def write(project_dir, workspace_id) do
    case Workspace.load(project_dir) do
      {:ok, ws} ->
        content = generate(ws, project_dir, workspace_id)
        compose_path = compose_path(project_dir)
        File.mkdir_p!(Path.dirname(compose_path))
        File.write!(compose_path, content)
        {:ok, compose_path}

      other ->
        other
    end
  end

  @doc "Path to the compose file."
  def compose_path(project_dir), do: Path.join([project_dir, ".hive", "docker-compose.yml"])

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

  @doc "Stop all services."
  def down(project_dir, workspace_id) do
    compose(project_dir, workspace_id, ["down"], timeout: 30_000)
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

  defp default_dockerfile do
    BoomLooper.Docker.dockerfile()
  end
end
