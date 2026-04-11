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
  3. Strip host ports (use dynamic allocation)
  """
  def process_agent_compose(compose_content, workspace_id) do
    code_volume = Workspace.volume_name_for(workspace_id)

    case Jason.decode(compose_content) do
      {:ok, compose} ->
        compose = update_in(compose, ["services"], fn services ->
          services
          |> Enum.map(fn {name, svc} ->
            svc = update_volumes_placeholder(svc, code_volume)
            svc = strip_host_ports(svc)
            {name, svc}
          end)
          |> Map.new()
        end)

        # Ensure code volume is declared as external
        volumes = Map.get(compose, "volumes", %{}) || %{}
        volumes = Map.put(volumes, code_volume, %{"external" => true})
        compose = Map.put(compose, "volumes", volumes)

        {:ok, Jason.encode!(compose, pretty: true)}

      {:error, _} ->
        # If not valid JSON, try YAML (compose files are usually YAML)
        case YamlElixir.read_from_string(compose_content) do
          {:ok, compose} ->
            compose = update_in(compose, ["services"], fn services ->
              services
              |> Enum.map(fn {name, svc} ->
                svc = update_volumes_placeholder(svc, code_volume)
                svc = strip_host_ports(svc)
                {name, svc}
              end)
              |> Map.new()
            end)

            volumes = Map.get(compose, "volumes", %{}) || %{}
            volumes = Map.put(volumes, code_volume, %{"external" => true})
            compose = Map.put(compose, "volumes", volumes)

            # Write back as JSON (docker compose accepts both)
            {:ok, Jason.encode!(compose, pretty: true)}

          {:error, reason} ->
            {:error, "Invalid compose file: #{inspect(reason)}"}
        end
    end
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

  defp strip_host_ports(svc) when is_map(svc) do
    case svc["ports"] do
      ports when is_list(ports) ->
        stripped = Enum.map(ports, &container_port_only/1)
        Map.put(svc, "ports", stripped)
      _ -> svc
    end
  end
  defp strip_host_ports(svc), do: svc

  # Strip host port from a port mapping, keeping only the container port.
  # "3001:3000" -> "3000", "3000" -> "3000", "3000/tcp" -> "3000/tcp"
  defp container_port_only(port_spec) when is_binary(port_spec) do
    case String.split(port_spec, ":") do
      [_host, container] -> container
      [container] -> container
      [_ip, _host, container] -> container
    end
  end
  defp container_port_only(port_spec), do: to_string(port_spec)

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
    compose(project_dir, workspace_id, ["up", "-d", "--build"], timeout: 600_000)
  end

  @doc """
  Start all services with streaming output. Calls `callback` with each chunk of output.
  Returns {:ok, full_output} or {:error, full_output} when done.
  """
  def up_stream(project_dir, workspace_id, callback) when is_function(callback, 1) do
    compose_file = compose_path(project_dir)
    project = project_name(workspace_id)

    base_args = ["-f", compose_file, "-p", project, "up", "-d", "--build", "--force-recreate"]

    # Use docker compose v2 (plugin) or standalone docker-compose
    if docker_compose_v2?() do
      stream_compose(["compose" | base_args], callback)
    else
      stream_docker_compose(base_args, callback)
    end
  end

  @doc """
  Start specific services with streaming output. Calls `callback` with each chunk of output.
  Returns {:ok, full_output} or {:error, full_output} when done.
  """
  def up_services_stream(project_dir, workspace_id, service_names, callback)
      when is_list(service_names) and is_function(callback, 1) do
    compose_file = compose_path(project_dir)
    project = project_name(workspace_id)

    base_args = ["-f", compose_file, "-p", project, "up", "-d", "--build", "--force-recreate" | service_names]

    if docker_compose_v2?() do
      stream_compose(["compose" | base_args], callback)
    else
      stream_docker_compose(base_args, callback)
    end
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

  defp stream_compose(args, callback) do
    BoomLooper.Docker.stream(args, callback, timeout: 600_000)
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

  defp parse_compose_ports(""), do: %{}
  defp parse_compose_ports(ports_str) do
    # Format: "0.0.0.0:32871->3000/tcp, :::32871->3000/tcp"
    Regex.scan(~r/(?:\d+\.){3}\d+:(\d+)->(\d+)/, ports_str)
    |> Map.new(fn [_, host_port, container_port] -> {container_port, host_port} end)
  end
end
