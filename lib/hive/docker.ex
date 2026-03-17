defmodule Hive.Docker do
  @moduledoc """
  Docker container lifecycle management for Hive agents.

  Each agent gets a container with:
  - A workspace volume (persists across rebuilds)
  - A cache volume (npm/pip/apt caches)
  - A port mapped for web server access
  - A wrapper script so the Claude SDK spawns claude inside the container
  """

  @prefix "hive-dev"
  @workspace_mount "/workspace"
  @cache_mount "/root/.cache"
  @base_port 10_000
  @container_internal_port 3000

  @base_dockerfile """
  FROM ubuntu:22.04

  ENV DEBIAN_FRONTEND=noninteractive

  RUN apt-get update && apt-get install -y \\
      curl git build-essential ca-certificates \\
      && rm -rf /var/lib/apt/lists/*

  # Install claude CLI
  RUN curl -fsSL https://cli.anthropic.com/install.sh | sh
  ENV PATH="/root/.claude/local/bin:${PATH}"

  WORKDIR #{@workspace_mount}
  CMD ["sleep", "infinity"]
  """

  # --- Public API ---

  @doc "Container name for an agent"
  def container_name(agent_id), do: "#{@prefix}-#{agent_id}"

  @doc "Workspace volume name for an agent"
  def workspace_volume(agent_id), do: "#{@prefix}-workspace-#{agent_id}"

  @doc "Cache volume name for an agent"
  def cache_volume(agent_id), do: "#{@prefix}-cache-#{agent_id}"

  @doc "Host port for an agent's web server"
  def host_port(agent_id) do
    # Deterministic port from agent_id hash
    hash = :erlang.phash2(agent_id, 5000)
    @base_port + hash
  end

  @doc "Returns the base Dockerfile content"
  def base_dockerfile, do: @base_dockerfile

  @doc """
  Create and start a container for an agent.

  Creates workspace + cache volumes, builds image from Dockerfile
  (or uses base), and starts the container.
  """
  def create(agent_id, opts \\ []) do
    name = container_name(agent_id)
    ws_vol = workspace_volume(agent_id)
    cache_vol = cache_volume(agent_id)
    port = host_port(agent_id)

    # Create volumes
    docker(["volume", "create", ws_vol])
    docker(["volume", "create", cache_vol])

    # Seed base Dockerfile into workspace if not present
    seed_dockerfile(agent_id, opts)

    # Build image
    case build(agent_id) do
      {:ok, _} -> :ok
      error -> error
    end
    |> case do
      :ok ->
        # Run container
        docker([
          "run", "-d",
          "--name", name,
          "-v", "#{ws_vol}:#{@workspace_mount}",
          "-v", "#{cache_vol}:#{@cache_mount}",
          "-p", "#{port}:#{@container_internal_port}",
          "-w", @workspace_mount,
          name,
          "sleep", "infinity"
        ])

      error ->
        error
    end
  end

  @doc """
  Build (or rebuild) the container image from the agent's Dockerfile.
  """
  def build(agent_id) do
    name = container_name(agent_id)
    ws_vol = workspace_volume(agent_id)

    # We need to get the Dockerfile out of the volume to build.
    # Use a temp container to read it.
    tmp = "#{name}-build-#{:rand.uniform(100_000)}"

    try do
      # Start temp container with the workspace volume
      case docker(["run", "-d", "--name", tmp, "-v", "#{ws_vol}:#{@workspace_mount}", "ubuntu:22.04", "sleep", "60"]) do
        {:ok, _} -> :ok
        {:error, msg} -> throw({:build_error, "Failed to start build container: #{msg}"})
      end

      # Check if Dockerfile exists in workspace
      case docker(["exec", tmp, "cat", "#{@workspace_mount}/Dockerfile"]) do
        {:ok, dockerfile_content} ->
          # Write to temp dir on host and build
          tmp_dir = Path.join(System.tmp_dir!(), "hive-build-#{agent_id}")
          File.mkdir_p!(tmp_dir)
          File.write!(Path.join(tmp_dir, "Dockerfile"), dockerfile_content)

          result = docker(["build", "-t", name, tmp_dir])
          File.rm_rf!(tmp_dir)
          result

        {:error, _} ->
          # No Dockerfile yet — use base
          tmp_dir = Path.join(System.tmp_dir!(), "hive-build-#{agent_id}")
          File.mkdir_p!(tmp_dir)
          File.write!(Path.join(tmp_dir, "Dockerfile"), @base_dockerfile)

          result = docker(["build", "-t", name, tmp_dir])
          File.rm_rf!(tmp_dir)
          result
      end
    catch
      {:build_error, msg} -> {:error, msg}
    after
      docker(["rm", "-f", tmp])
    end
  end

  @doc """
  Rebuild: stop container, rebuild image, start fresh container with same volumes.
  """
  def rebuild(agent_id) do
    stop(agent_id)
    build(agent_id)
    |> case do
      {:ok, _} -> start(agent_id)
      error -> error
    end
  end

  @doc "Start a stopped container (or create a new one with existing volumes)"
  def start(agent_id) do
    name = container_name(agent_id)
    ws_vol = workspace_volume(agent_id)
    cache_vol = cache_volume(agent_id)
    port = host_port(agent_id)

    docker([
      "run", "-d",
      "--name", name,
      "-v", "#{ws_vol}:#{@workspace_mount}",
      "-v", "#{cache_vol}:#{@cache_mount}",
      "-p", "#{port}:#{@container_internal_port}",
      "-w", @workspace_mount,
      name,
      "sleep", "infinity"
    ])
  end

  @doc "Stop and remove the container (volumes preserved)"
  def stop(agent_id) do
    docker(["rm", "-f", container_name(agent_id)])
  end

  @doc "Destroy everything: container + volumes"
  def destroy(agent_id) do
    stop(agent_id)
    docker(["volume", "rm", "-f", workspace_volume(agent_id)])
    docker(["volume", "rm", "-f", cache_volume(agent_id)])
    :ok
  end

  @doc "Execute a command in the container"
  def exec(agent_id, command) do
    docker(["exec", container_name(agent_id), "sh", "-c", command])
  end

  @doc """
  Generate a CLI wrapper script that runs claude inside the container.

  The SDK uses `cli_path` to find the claude binary. We give it this
  script, which does `docker exec -i {container} claude "$@"`.
  Returns the path to the wrapper script.
  """
  def cli_wrapper_path(agent_id) do
    dir = Path.join(System.tmp_dir!(), "hive-wrappers")
    File.mkdir_p!(dir)
    path = Path.join(dir, "claude-#{agent_id}")

    script = """
    #!/bin/sh
    exec docker exec -i #{container_name(agent_id)} claude "$@"
    """

    File.write!(path, script)
    File.chmod!(path, 0o755)
    path
  end

  @doc "Check if a container is running"
  def running?(agent_id) do
    case docker(["inspect", "-f", "{{.State.Running}}", container_name(agent_id)]) do
      {:ok, output} -> String.trim(output) == "true"
      _ -> false
    end
  end

  # --- Private ---

  defp seed_dockerfile(agent_id, opts) do
    ws_vol = workspace_volume(agent_id)
    dockerfile_content = Keyword.get(opts, :dockerfile, @base_dockerfile)

    # Use a temp container to write the Dockerfile into the volume
    tmp = "#{container_name(agent_id)}-seed-#{:rand.uniform(100_000)}"

    docker(["run", "-d", "--name", tmp, "-v", "#{ws_vol}:#{@workspace_mount}", "ubuntu:22.04", "sleep", "30"])

    # Only seed if no Dockerfile exists yet
    case docker(["exec", tmp, "test", "-f", "#{@workspace_mount}/Dockerfile"]) do
      {:ok, _} ->
        :ok

      {:error, _} ->
        # Write Dockerfile via stdin
        docker_stdin(["exec", "-i", tmp, "tee", "#{@workspace_mount}/Dockerfile"], dockerfile_content)
    end

    docker(["rm", "-f", tmp])
  end

  defp docker(args) do
    case System.cmd("docker", args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, _code} -> {:error, String.trim(output)}
    end
  end

  defp docker_stdin(args, input) do
    port = Port.open({:spawn_executable, docker_path()}, [
      :binary, :exit_status,
      {:args, args},
      :stderr_to_stdout
    ])

    Port.command(port, input)
    Port.command(port, "")
    Port.close(port)
    :ok
  end

  defp docker_path do
    System.find_executable("docker") || raise "docker not found in PATH"
  end
end
