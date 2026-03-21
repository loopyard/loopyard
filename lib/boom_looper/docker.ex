defmodule BoomLooper.Docker do
  @moduledoc """
  Docker container lifecycle management for BoomLooper workspaces.

  Each workspace gets a single shared container that all agents exec into.
  The workspace container runs project processes (web, CSS, JS) via
  a process manager entrypoint. Stock services (postgres, redis) run
  as separate containers managed by ServiceManager.
  """

  @ws_prefix "boom-looper-ws"
  @workspace_mount "/workspace"
  @cache_mount "/root/.cache"

  @network_name "boom-looper-net"

  @dockerfile """
  FROM ubuntu:24.04
  ENV DEBIAN_FRONTEND=noninteractive

  RUN apt-get update && apt-get install -y \\
      git build-essential ca-certificates gnupg curl \\
      && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \\
         | gpg --dearmor -o /usr/share/keyrings/githubcli-archive-keyring.gpg \\
      && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \\
         | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \\
      && apt-get update && apt-get install -y gh \\
      && rm -rf /var/lib/apt/lists/*

  WORKDIR #{@workspace_mount}
  CMD ["sleep", "infinity"]
  """

  # --- Public API ---

  @doc "Returns the default Dockerfile content"
  def dockerfile, do: @dockerfile

  @doc "Returns the Docker network name used by all BoomLooper containers"
  def network_name, do: @network_name

  @doc "Image name for a workspace"
  def workspace_image_name(workspace_id), do: "#{@ws_prefix}-#{workspace_id}"

  @doc "Cache volume name shared by all agents in a workspace"
  def cache_volume_for_workspace(workspace_id), do: "#{@ws_prefix}-cache-#{workspace_id}"

  @doc "Container name for a workspace"
  def workspace_container_name(workspace_id), do: "#{@ws_prefix}-#{workspace_id}"

  @doc "Build the workspace Docker image from a Dockerfile string"
  def build_workspace_image(workspace_id, dockerfile) do
    build_from_string(workspace_image_name(workspace_id), dockerfile)
  end

  @doc "Get the host port mappings for a container. Returns %{container_port => host_port}."
  def container_ports(container_name) do
    case docker(["port", container_name]) do
      {:ok, output} ->
        output
        |> String.split("\n", trim: true)
        |> Map.new(fn line ->
          # Format: "3000/tcp -> 0.0.0.0:49152"
          case Regex.run(~r/(\d+)\/\w+\s+->\s+[\d.]+:(\d+)/, line) do
            [_, container_port, host_port] -> {container_port, host_port}
            _ -> {line, nil}
          end
        end)
        |> Enum.reject(fn {_, v} -> is_nil(v) end)
        |> Map.new()

      {:error, _} ->
        %{}
    end
  end

  @doc "Get VOLUME declarations from a Docker image. Returns list of paths."
  def image_volumes(image_name) do
    case docker(["inspect", image_name, "--format", "{{json .Config.Volumes}}"]) do
      {:ok, output} ->
        case Jason.decode(String.trim(output)) do
          {:ok, volumes} when is_map(volumes) -> Map.keys(volumes)
          _ -> []
        end

      {:error, _} ->
        # Image might not be pulled yet — try pulling first
        case docker(["pull", image_name], timeout: 120_000) do
          {:ok, _} ->
            case docker(["inspect", image_name, "--format", "{{json .Config.Volumes}}"]) do
              {:ok, output} ->
                case Jason.decode(String.trim(output)) do
                  {:ok, volumes} when is_map(volumes) -> Map.keys(volumes)
                  _ -> []
                end
              _ -> []
            end
          _ -> []
        end
    end
  end

  @doc "Check if a TCP port has a process listening (not just Docker proxy)."
  def port_open?(port) when is_binary(port), do: port_open?(String.to_integer(port))
  def port_open?(port) when is_integer(port) do
    case :gen_tcp.connect(~c"localhost", port, [:binary, active: false], 1_000) do
      {:ok, socket} ->
        # Try to receive data within 500ms — if Docker proxy is forwarding
        # to nothing, we'll get {:error, :closed} or timeout
        result = case :gen_tcp.recv(socket, 0, 500) do
          {:ok, _data} -> true          # Got data — server is responding
          {:error, :timeout} -> true    # Connected but no data yet — still alive
          {:error, :closed} -> false    # Docker proxy connected but backend isn't there
        end
        :gen_tcp.close(socket)
        result

      {:error, _} ->
        false
    end
  end

  @doc "Check if a container is running by name"
  def container_running?(container_name) do
    case docker(["inspect", "-f", "{{.State.Running}}", container_name]) do
      {:ok, output} -> String.trim(output) == "true"
      _ -> false
    end
  end

  @doc "Get container state details — running, exit code, error, OOM status."
  def container_state(container_name) do
    case docker(["inspect", "-f", "{{.State.Status}}|{{.State.ExitCode}}|{{.State.OOMKilled}}|{{.State.Error}}", container_name]) do
      {:ok, output} ->
        case output |> String.trim() |> String.split("|") do
          [status, exit_code, oom, error] ->
            %{
              status: status,
              exit_code: String.to_integer(exit_code),
              oom_killed: oom == "true",
              error: if(error == "", do: nil, else: error)
            }
          _ -> nil
        end
      _ -> nil
    end
  end

  @doc "Check if the workspace container is running"
  def workspace_container_running?(workspace_id) do
    container_running?(workspace_container_name(workspace_id))
  end

  @doc """
  Start the workspace container.

  Options:
  - `:bind_mount` — host directory to bind-mount as /workspace
  - `:env_vars` — map of environment variables
  - `:ports` — list of "host:container" port mapping strings
  - `:command` — command to run (defaults to ["sleep", "infinity"])
  """
  def start_workspace_container(workspace_id, opts \\ []) do
    ensure_network()

    name = workspace_container_name(workspace_id)
    image = workspace_image_name(workspace_id)
    cache_vol = cache_volume_for_workspace(workspace_id)
    bind_mount = Keyword.get(opts, :bind_mount)
    extra_env = Keyword.get(opts, :env_vars, %{})
    ports = Keyword.get(opts, :ports, [])
    command = Keyword.get(opts, :command, ["sleep", "infinity"])

    # Remove stopped container with same name (but not running ones)
    unless container_running?(name), do: docker(["rm", "-f", name])

    # Create cache volume
    docker(["volume", "create", cache_vol])

    workspace_args =
      if bind_mount do
        ["--mount", "type=bind,src=#{bind_mount},dst=#{@workspace_mount}"]
      else
        vol_name = "#{@ws_prefix}-workspace-#{workspace_id}"
        docker(["volume", "create", vol_name])
        ["-v", "#{vol_name}:#{@workspace_mount}"]
      end

    port_args = Enum.flat_map(ports, fn port_str -> ["-p", port_str] end)
    env_args = container_env_args() ++ extra_env_args(extra_env)

    base_args = [
      "run", "-d",
      "--name", name,
      "--network", @network_name
    ] ++ workspace_args ++ [
      "-v", "#{cache_vol}:#{@cache_mount}",
      "-w", @workspace_mount
    ] ++ port_args ++ env_args

    result = docker(base_args ++ [image] ++ command)

    case result do
      {:ok, _} = ok ->
        setup_git_config_in(name)
        ok
      error ->
        error
    end
  end

  @doc "Stop and remove the workspace container"
  def stop_workspace_container(workspace_id) do
    docker(["rm", "-f", workspace_container_name(workspace_id)])
  end

  @doc "Execute a command in the workspace container"
  def exec_workspace(workspace_id, command, opts \\ []) do
    exec_in(workspace_container_name(workspace_id), command, opts)
  end

  @doc "Execute a command in any container by name"
  def exec_in(container_name, command, opts \\ []) do
    workdir = Keyword.get(opts, :workdir)
    timeout = Keyword.get(opts, :timeout, 120_000)

    args = ["exec"]
    args = if workdir, do: args ++ ["-w", workdir], else: args
    args = args ++ [container_name, "sh", "-c", command]

    docker(args, timeout: timeout)
  end

  @doc "Get logs from any container by name"
  def container_logs(container_name, opts \\ []) do
    tail = Keyword.get(opts, :tail, 200)
    docker(["logs", "--tail", "#{tail}", container_name], timeout: 5_000)
  end

  @doc "Get logs from the workspace container"
  def workspace_container_logs(workspace_id, opts \\ []) do
    container_logs(workspace_container_name(workspace_id), opts)
  end

  @doc """
  Build a bash entrypoint script that runs multiple processes with prefixed output.
  Each process map must have :name and :command keys.
  """
  def build_process_entrypoint(processes) when is_list(processes) do
    process_lines =
      Enum.map(processes, fn p ->
        name = p.name || p[:name]
        cmd = p.command || p[:command]
        pad = String.pad_trailing(name, 8)
        "(#{cmd}) 2>&1 | sed \"s/^/#{pad}| /\" &"
      end)

    """
    #!/bin/bash
    trap 'kill $(jobs -p) 2>/dev/null; wait' SIGTERM SIGINT

    #{Enum.join(process_lines, "\n")}

    wait
    """
  end

  @doc """
  List all BoomLooper containers (workspace + service).

  Returns a list of maps with :name, :status, and :type fields.

  Options:
  - `:prefix` — filter by container name prefix (e.g., "boom-looper-svc-myws")
  """
  def list_containers(opts \\ []) do
    filter_prefix = Keyword.get(opts, :prefix, "boom-looper-")

    case docker(["ps", "-a", "--filter", "name=#{filter_prefix}",
                  "--format", "{{.Names}}\t{{.Status}}"]) do
      {:ok, ""} ->
        []

      {:ok, output} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.map(fn line ->
          case String.split(line, "\t", parts: 2) do
            [name, status] ->
              %{
                name: name,
                status: status,
                type: classify_container(name),
                running: String.starts_with?(status, "Up")
              }

            _ ->
              nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      {:error, _} ->
        []
    end
  end

  defp classify_container("boom-looper-ws-" <> _), do: :workspace
  defp classify_container("boom-looper-svc-" <> _), do: :service
  defp classify_container(_), do: :unknown

  # --- Private ---

  @doc "Ensure the Docker network exists"
  def ensure_network do
    case docker(["network", "inspect", @network_name]) do
      {:ok, _} -> :ok
      {:error, _} -> docker(["network", "create", @network_name])
    end

    :ok
  end

  @env_vars_to_pass ~w(GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL)

  defp container_env_args do
    Enum.flat_map(@env_vars_to_pass, fn var ->
      case System.get_env(var) do
        nil -> []
        val -> ["-e", "#{var}=#{val}"]
      end
    end)
  end

  defp extra_env_args(env_map) when is_map(env_map) do
    Enum.flat_map(env_map, fn {k, v} -> ["-e", "#{k}=#{v}"] end)
  end

  defp setup_git_config_in(container_name) do
    git_name = System.get_env("GIT_AUTHOR_NAME") || "BoomLooper Agent"
    git_email = System.get_env("GIT_AUTHOR_EMAIL") || "agent@boom-looper.local"

    git_setup = """
    git config --global user.name "#{git_name}" && \
    git config --global user.email "#{git_email}"
    """

    docker(["exec", container_name, "sh", "-c", git_setup])
  end

  defp build_from_string(image_name, dockerfile_content) do
    tmp_dir = Path.join(System.tmp_dir!(), "boom-looper-build-#{image_name}-#{:rand.uniform(100_000)}")
    File.mkdir_p!(tmp_dir)
    File.write!(Path.join(tmp_dir, "Dockerfile"), dockerfile_content)

    # Stream build output line by line via PubSub
    topic = "docker_build:#{image_name}"
    args = ["build", "-t", image_name, tmp_dir]
    port = Port.open({:spawn_executable, System.find_executable("docker")},
      [:binary, :exit_status, :stderr_to_stdout, args: args])

    result = collect_port_output(port, topic, [])
    File.rm_rf!(tmp_dir)
    result
  end

  defp collect_port_output(port, topic, acc) do
    receive do
      {^port, {:data, data}} ->
        Phoenix.PubSub.broadcast(BoomLooper.PubSub, topic, {:build_output, data})
        collect_port_output(port, topic, [data | acc])

      {^port, {:exit_status, 0}} ->
        Phoenix.PubSub.broadcast(BoomLooper.PubSub, topic, :build_complete)
        {:ok, acc |> Enum.reverse() |> Enum.join()}

      {^port, {:exit_status, _code}} ->
        Phoenix.PubSub.broadcast(BoomLooper.PubSub, topic, :build_failed)
        {:error, acc |> Enum.reverse() |> Enum.join()}
    after
      600_000 ->
        Port.close(port)
        {:error, "Build timed out"}
    end
  end

  @doc "Execute a raw docker CLI command. Returns {:ok, output} or {:error, output}."
  def docker(args, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 120_000)

    task =
      Task.async(fn ->
        System.cmd("docker", args, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, {output, 0}} -> {:ok, String.trim(output)}
      {:ok, {output, _code}} -> {:error, String.trim(output)}
      nil -> {:error, "Command timed out after #{timeout}ms"}
    end
  end
end
