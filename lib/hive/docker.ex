defmodule Hive.Docker do
  @moduledoc """
  Docker container lifecycle management for Hive agents.

  Each agent gets a container with:
  - A workspace (bind-mounted host directory or named volume)
  - A cache volume (npm/pip/apt caches, persists across rebuilds)
  - A port mapped for web server access
  """

  @prefix "hive-dev"
  @workspace_mount "/workspace"
  @cache_mount "/root/.cache"
  @base_port 10_000
  @container_internal_port 3000

  @network_name "hive-net"

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

  @doc "Container name for an agent"
  def container_name(agent_id), do: "#{@prefix}-#{agent_id}"

  @doc "Workspace volume name for an agent"
  def workspace_volume(agent_id), do: "#{@prefix}-workspace-#{agent_id}"

  @doc "Cache volume name for an agent"
  def cache_volume(agent_id), do: "#{@prefix}-cache-#{agent_id}"

  @doc "Host port for an agent's web server"
  def host_port(agent_id) do
    hash = :erlang.phash2(agent_id, 5000)
    @base_port + hash
  end

  @doc "Returns the default Dockerfile content"
  def dockerfile, do: @dockerfile

  @doc "Returns the Docker network name used by all Hive containers"
  def network_name, do: @network_name

  @doc """
  Create and start a container for an agent.

  Options:
  - `:dockerfile` — Dockerfile content (defaults to the built-in Ubuntu image)
  - `:bind_mount` — host directory to bind-mount as /workspace
  - `:env_vars` — map of additional environment variables
  """
  def create(agent_id, opts \\ []) do
    df = Keyword.get(opts, :dockerfile, @dockerfile)
    bind_mount = Keyword.get(opts, :bind_mount)
    env_vars = Keyword.get(opts, :env_vars, %{})

    create_volumes(agent_id, bind_mount: bind_mount)

    start_opts = [bind_mount: bind_mount, env_vars: env_vars]
    start_opts = Enum.reject(start_opts, fn {_k, v} -> is_nil(v) end)

    with {:ok, _} <- build_image(agent_id, df),
         {:ok, _} = ok <- start_container(agent_id, start_opts) do
      ok
    end
  end

  @doc "Create volumes for an agent. Skips workspace volume when bind_mount is set."
  def create_volumes(agent_id, opts \\ []) do
    unless Keyword.get(opts, :bind_mount), do: docker(["volume", "create", workspace_volume(agent_id)])
    docker(["volume", "create", cache_volume(agent_id)])
    :ok
  end

  @doc "Build the Docker image"
  def build_image(agent_id, df \\ @dockerfile) do
    build_from_string(container_name(agent_id), df)
  end

  @doc """
  Start the container from its built image.

  Options:
  - `:bind_mount` — host directory to bind-mount as /workspace instead of using a named volume
  - `:env_vars` — map of additional environment variables to pass to the container
  """
  def start_container(agent_id, opts \\ []) do
    ensure_network()

    name = container_name(agent_id)
    cache_vol = cache_volume(agent_id)
    port = host_port(agent_id)
    bind_mount = Keyword.get(opts, :bind_mount)
    extra_env = Keyword.get(opts, :env_vars, %{})

    workspace_args =
      if bind_mount do
        ["--mount", "type=bind,src=#{bind_mount},dst=#{@workspace_mount}"]
      else
        ["-v", "#{workspace_volume(agent_id)}:#{@workspace_mount}"]
      end

    base_args = [
      "run", "-d",
      "--name", name,
      "--network", @network_name
    ] ++ workspace_args ++ [
      "-v", "#{cache_vol}:#{@cache_mount}",
      "-p", "#{port}:#{@container_internal_port}",
      "-w", @workspace_mount
    ]

    env_args = container_env_args() ++ extra_env_args(extra_env)

    result = docker(base_args ++ env_args ++ [name, "sleep", "infinity"])

    case result do
      {:ok, _} = ok ->
        setup_git_config(agent_id)
        ok

      error ->
        error
    end
  end

  @doc """
  Rebuild an agent's container with a new Dockerfile.
  Stops the old container, builds a new image, starts a new container
  with the same mounts and network. The Claude CLI session stays alive.

  Options:
  - `:bind_mount` — host directory to bind-mount
  - `:env_vars` — map of extra environment variables
  """
  def rebuild(agent_id, dockerfile, opts \\ []) do
    bind_mount = Keyword.get(opts, :bind_mount)
    env_vars = Keyword.get(opts, :env_vars, %{})

    # Build the new image FIRST, before stopping the old container.
    # If the build fails, the old container is still running.
    with {:ok, _} <- build_image(agent_id, dockerfile),
         {:ok, _} <- stop(agent_id) do
      start_opts = [env_vars: env_vars]
      start_opts = if bind_mount, do: Keyword.put(start_opts, :bind_mount, bind_mount), else: start_opts
      start_container(agent_id, start_opts)
    end
  end

  @doc "Stop and remove the container (volumes preserved)"
  def stop(agent_id) do
    docker(["rm", "-f", container_name(agent_id)])
  end

  @doc "Destroy everything: container, volumes, and image"
  def destroy(agent_id) do
    stop(agent_id)
    docker(["volume", "rm", "-f", workspace_volume(agent_id)])
    docker(["volume", "rm", "-f", cache_volume(agent_id)])
    docker(["rmi", "-f", container_name(agent_id)])
    :ok
  end

  @doc "Execute a command in the container"
  def exec(agent_id, command, opts \\ []) do
    workdir = Keyword.get(opts, :workdir)
    timeout = Keyword.get(opts, :timeout, 120_000)

    args = ["exec"]
    args = if workdir, do: args ++ ["-w", workdir], else: args
    args = args ++ [container_name(agent_id), "sh", "-c", command]

    docker(args, timeout: timeout)
  end

  @doc "Check if a container is running"
  def running?(agent_id) do
    case docker(["inspect", "-f", "{{.State.Running}}", container_name(agent_id)]) do
      {:ok, output} -> String.trim(output) == "true"
      _ -> false
    end
  end

  # --- Private ---

  @doc "Ensure the Docker network exists"
  def ensure_network do
    case docker(["network", "inspect", @network_name]) do
      {:ok, _} -> :ok
      {:error, _} -> docker(["network", "create", @network_name])
    end

    :ok
  end

  @env_vars_to_pass ~w(GITHUB_TOKEN GH_TOKEN GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL)

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

  defp setup_git_config(agent_id) do
    git_name = System.get_env("GIT_AUTHOR_NAME") || "Hive Agent"
    git_email = System.get_env("GIT_AUTHOR_EMAIL") || "agent@hive.local"

    git_setup = """
    git config --global user.name "#{git_name}" && \
    git config --global user.email "#{git_email}" && \
    if [ -n "$GH_TOKEN" ] || [ -n "$GITHUB_TOKEN" ]; then
      TOKEN="${GH_TOKEN:-$GITHUB_TOKEN}"
      git config --global credential.helper '!f() { echo "password=$TOKEN"; }; f'
    fi
    """

    exec(agent_id, git_setup)
  end

  defp build_from_string(image_name, dockerfile_content) do
    tmp_dir = Path.join(System.tmp_dir!(), "hive-build-#{image_name}-#{:rand.uniform(100_000)}")
    File.mkdir_p!(tmp_dir)
    File.write!(Path.join(tmp_dir, "Dockerfile"), dockerfile_content)

    result = docker(["build", "-t", image_name, tmp_dir], timeout: 600_000)
    File.rm_rf!(tmp_dir)
    result
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
