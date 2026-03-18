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

  @network_name "hive-net"

  @base_dockerfile """
  FROM ubuntu:22.04
  ENV DEBIAN_FRONTEND=noninteractive

  RUN apt-get update && apt-get install -y \\
      curl git build-essential ca-certificates gnupg \\
      && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \\
         | gpg --dearmor -o /usr/share/keyrings/githubcli-archive-keyring.gpg \\
      && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \\
         | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \\
      && apt-get update && apt-get install -y gh \\
      && rm -rf /var/lib/apt/lists/*

  WORKDIR #{@workspace_mount}
  CMD ["sleep", "infinity"]
  """

  @root_dockerfile """
  FROM elixir:1.18
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

  @doc "Returns the base Dockerfile content"
  def base_dockerfile, do: @base_dockerfile

  @doc "Returns the root Dockerfile content (Elixir/Erlang pre-installed)"
  def root_dockerfile, do: @root_dockerfile

  @doc "Returns the Docker network name used by all Hive containers"
  def network_name, do: @network_name

  @doc """
  Create and start a container for an agent.

  Options:
  - `:dockerfile` — Dockerfile content (defaults to `base_dockerfile`)
  - `:bind_mount` — host directory to bind-mount as /workspace. When set,
    no workspace volume is created and no Dockerfile is seeded into workspace.
  """
  def create(agent_id, opts \\ []) do
    dockerfile = Keyword.get(opts, :dockerfile, @base_dockerfile)
    bind_mount = Keyword.get(opts, :bind_mount)

    create_volumes(agent_id, bind_mount: bind_mount)

    with {:ok, _} <- build_image(agent_id, dockerfile),
         {:ok, _} = ok <- start_container(agent_id, bind_mount: bind_mount) do
      unless bind_mount, do: seed_dockerfile(agent_id, dockerfile)
      ok
    end
  end

  @doc "Create volumes for an agent. Skips workspace volume when bind_mount is set."
  def create_volumes(agent_id, opts \\ []) do
    unless Keyword.get(opts, :bind_mount), do: docker(["volume", "create", workspace_volume(agent_id)])
    docker(["volume", "create", cache_volume(agent_id)])
    :ok
  end

  @doc "Build the Docker image from the base Dockerfile (or custom)"
  def build_image(agent_id, dockerfile \\ @base_dockerfile) do
    build_from_string(container_name(agent_id), dockerfile)
  end

  @doc """
  Start the container from its built image.

  Options:
  - `:bind_mount` — host directory to bind-mount as /workspace instead of using a named volume
  """
  def start_container(agent_id, opts \\ []) do
    ensure_network()

    name = container_name(agent_id)
    cache_vol = cache_volume(agent_id)
    port = host_port(agent_id)
    bind_mount = Keyword.get(opts, :bind_mount)

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

    env_args = container_env_args()

    result = docker(base_args ++ env_args ++ [name, "sleep", "infinity"])

    case result do
      {:ok, _} = ok ->
        setup_git_config(agent_id)
        ok

      error ->
        error
    end
  end

  @doc "Seed the Dockerfile into the workspace so the agent can edit and rebuild"
  def seed_dockerfile(agent_id, dockerfile \\ @base_dockerfile) do
    exec(agent_id, "test -f #{@workspace_mount}/Dockerfile || cat > #{@workspace_mount}/Dockerfile << 'DOCKERFILE'\n#{dockerfile}\nDOCKERFILE")
  end

  @doc """
  Rebuild: read Dockerfile from container's workspace, rebuild image, restart.
  This is the self-improving path — agent edits Dockerfile, calls rebuild.
  """
  def rebuild(agent_id) do
    name = container_name(agent_id)

    # Read the (possibly modified) Dockerfile from the running container
    dockerfile =
      case exec(agent_id, "cat #{@workspace_mount}/Dockerfile") do
        {:ok, content} -> content
        {:error, _} -> @base_dockerfile
      end

    stop(agent_id)

    with {:ok, _} <- build_from_string(name, dockerfile) do
      start(agent_id)
    end
  end

  @doc "Start a new container from existing image and volumes"
  def start(agent_id) do
    ensure_network()

    name = container_name(agent_id)
    ws_vol = workspace_volume(agent_id)
    cache_vol = cache_volume(agent_id)
    port = host_port(agent_id)

    base_args = [
      "run", "-d",
      "--name", name,
      "--network", @network_name,
      "-v", "#{ws_vol}:#{@workspace_mount}",
      "-v", "#{cache_vol}:#{@cache_mount}",
      "-p", "#{port}:#{@container_internal_port}",
      "-w", @workspace_mount
    ]

    env_args = container_env_args()

    result = docker(base_args ++ env_args ++ [name, "sleep", "infinity"])

    case result do
      {:ok, _} = ok ->
        setup_git_config(agent_id)
        ok

      error ->
        error
    end
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

  defp ensure_network do
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

    result = docker(["build", "-t", image_name, tmp_dir])
    File.rm_rf!(tmp_dir)
    result
  end

  defp docker(args, opts \\ []) do
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
