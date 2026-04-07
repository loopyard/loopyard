defmodule BoomLooper.Tools.Container do
  @moduledoc """
  MCP tools for interacting with Docker containers.

  Workspace agents exec into the workspace container (always alive, sleep infinity).
  Service agents exec into their service's container (dev, postgres, etc.).
  """
  use ClaudeCode.MCP.Server, name: "boom-looper-container"

  alias BoomLooper.Docker
  alias BoomLooper.Workspace.ServiceManager

  # --- Public API ---

  def do_exec(agent_id, command, opts \\ %{}) do
    case resolve_container(agent_id) do
      {:ok, container} ->
        exec_opts = []
        exec_opts = if Map.has_key?(opts, :workdir), do: Keyword.put(exec_opts, :workdir, opts.workdir), else: exec_opts
        # Tool accepts seconds, Docker.exec_in expects milliseconds
        exec_opts = if Map.has_key?(opts, :timeout), do: Keyword.put(exec_opts, :timeout, opts.timeout * 1_000), else: exec_opts

        Docker.exec_in(container, command, exec_opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def do_logs(agent_id, opts \\ %{}) do
    service = Map.get(opts, :service)
    lines = Map.get(opts, :lines, 200)

    if service do
      # Logs for a specific service container
      case resolve_service_container(agent_id, service) do
        {:ok, container} -> Docker.container_logs(container, tail: lines)
        {:error, reason} -> {:error, reason}
      end
    else
      # Logs for the agent's own container
      case resolve_container(agent_id) do
        {:ok, container} -> Docker.container_logs(container, tail: lines)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def do_ports(agent_id) do
    case resolve_container(agent_id) do
      {:ok, container} ->
        Docker.exec_in(container, """
        echo "=== Listening ports ==="
        ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null || echo "[not available]"
        """)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def do_inspect(agent_id) do
    case resolve_container(agent_id) do
      {:ok, container} ->
        checks = [
          {"Running processes", "ps aux --no-headers 2>/dev/null || ps 2>/dev/null"},
          {"Listening ports", "ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null || echo '[ss/netstat not available]'"},
          {"Installed languages", "for cmd in node python3 ruby go java elixir; do which $cmd 2>/dev/null && $cmd --version 2>&1 | head -1; done"},
          {"Installed databases", "for cmd in psql mysql redis-cli mongosh sqlite3; do which $cmd 2>/dev/null && echo \"  $cmd available\"; done"},
          {"Installed tools", "for cmd in git curl wget make gcc npm yarn pip cargo mix bundle; do which $cmd 2>/dev/null; done"},
          {"Disk usage", "df -h /workspace 2>/dev/null | tail -1"}
        ]

        results =
          Enum.map(checks, fn {label, cmd} ->
            output = case Docker.exec_in(container, cmd) do
              {:ok, out} -> String.trim(out)
              {:error, _} -> "[error]"
            end
            "## #{label}\n#{output}"
          end)

        {:ok, Enum.join(results, "\n\n")}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- Tool definitions ---

  tool :exec, "Run a shell command inside the container. Use timeout for long-running commands (dependency installs, builds, etc.)." do
    field :agent_id, :string, required: true
    field :command, :string, required: true
    field :workdir, :string, required: false
    field :timeout, :integer, required: false, description: "Max seconds to run (default: 120)"

    def execute(%{agent_id: agent_id, command: command} = params) do
      BoomLooper.Tools.Container.do_exec(agent_id, command, params)
    end
  end

  tool :exec_stream, "Run a long-running command with streaming output (e.g. ping, tail -f, watch). Output streams into the chat. The command runs in the background — you can keep working." do
    field :agent_id, :string, required: true
    field :command, :string, required: true
    field :timeout, :integer, required: false, description: "Max seconds to run (default: 30)"

    def execute(%{agent_id: agent_id, command: command} = params) do
      BoomLooper.Tools.Container.do_exec_stream(agent_id, command, Map.get(params, :timeout, 30))
    end
  end

  tool :logs, "View container logs (works on running AND stopped/crashed containers). Pass 'service' to see a specific service's logs (e.g. 'dev', 'postgres'). Use service_containers first to see what's available." do
    field :agent_id, :string, required: true
    field :service, :string, required: false, description: "Service name to get logs for (e.g. 'dev', 'postgres', 'redis')"
    field :lines, :integer, required: false

    def execute(%{agent_id: agent_id} = params) do
      BoomLooper.Tools.Container.do_logs(agent_id, params)
    end
  end

  tool :inspect_env, "Inspect the container environment: installed languages, databases, tools, running processes, listening ports" do
    field :agent_id, :string, required: true

    def execute(%{agent_id: agent_id}) do
      BoomLooper.Tools.Container.do_inspect(agent_id)
    end
  end

  tool :service_containers, "List all containers for this workspace. Call ONCE after rebuild completes. Do NOT poll — if containers aren't up, read logs instead." do
    field :agent_id, :string, required: true

    def execute(%{agent_id: agent_id}) do
      BoomLooper.Tools.Container.do_service_containers(agent_id)
    end
  end

  tool :ports, "Show all listening ports in the container" do
    field :agent_id, :string, required: true

    def execute(%{agent_id: agent_id}) do
      BoomLooper.Tools.Container.do_ports(agent_id)
    end
  end

  tool :write_file, "Write a file to the workspace. Use for Dockerfile, docker-compose.yml, config files, etc. Path is relative to /workspace." do
    field :agent_id, :string, required: true
    field :path, :string, required: true, description: "File path relative to /workspace (e.g. '.boomlooper/workspace/Dockerfile' or '.boomlooper/workspace/docker-compose.yml')"
    field :content, :string, required: true, description: "File content"

    def execute(%{agent_id: agent_id, path: path, content: content}) do
      BoomLooper.Tools.Container.do_write_file(agent_id, path, content)
    end
  end

  tool :read_file, "Read a file from the workspace. Path is relative to /workspace." do
    field :agent_id, :string, required: true
    field :path, :string, required: true, description: "File path relative to /workspace"

    def execute(%{agent_id: agent_id, path: path}) do
      BoomLooper.Tools.Container.do_read_file(agent_id, path)
    end
  end

  tool :docker, "Run any Docker CLI command. Use for inspecting containers, volumes, images, networks, etc." do
    field :agent_id, :string, required: true
    field :command, :string, required: true, description: "Docker command (e.g. 'ps -a', 'volume ls', 'inspect mycontainer', 'images')"
    field :timeout, :integer, required: false, description: "Max seconds to run (default: 30)"

    def execute(%{agent_id: _agent_id, command: command} = params) do
      BoomLooper.Tools.Container.do_docker(command, Map.get(params, :timeout, 30))
    end
  end

  tool :docker_compose, "Run any docker compose command. Compose file is at .boomlooper/workspace/docker-compose.yml" do
    field :agent_id, :string, required: true
    field :command, :string, required: true, description: "Compose command (e.g. 'up -d --build', 'down', 'ps', 'logs dev', 'restart dev')"
    field :timeout, :integer, required: false, description: "Max seconds to run (default: 300 for builds)"

    def execute(%{agent_id: agent_id, command: command} = params) do
      BoomLooper.Tools.Container.do_docker_compose(agent_id, command, Map.get(params, :timeout, 300))
    end
  end

  tool :workspace_info, "Get workspace metadata: ID, volume name, paths, container names" do
    field :agent_id, :string, required: true

    def execute(%{agent_id: agent_id}) do
      BoomLooper.Tools.Container.do_workspace_info(agent_id)
    end
  end

  tool :volumes, "List and inspect Docker volumes for this workspace" do
    field :agent_id, :string, required: true
    field :action, :string, required: false, description: "Action: 'list' (default), 'ls <volume> [path]', 'info <volume>'"

    def execute(%{agent_id: agent_id} = params) do
      BoomLooper.Tools.Container.do_volumes(agent_id, Map.get(params, :action, "list"))
    end
  end

  def do_write_file(agent_id, path, content) do
    # Sanitize path - must be relative, no ..
    if String.contains?(path, "..") do
      {:error, "Path cannot contain '..'"}
    else
      case BoomLooper.ChatAgent.get_state(agent_id) do
        %{workspace_id: workspace_id} when is_binary(workspace_id) ->
          volume_name = BoomLooper.Workspace.volume_name_for(workspace_id)

          # Substitute variables in compose files
          content = if String.ends_with?(path, "docker-compose.yml") do
            content
            |> String.replace("${CODE_VOLUME}", volume_name)
            |> String.replace("${WORKSPACE_ID}", workspace_id)
          else
            content
          end

          # Use VolumeManager - handles running container vs temporary container
          case BoomLooper.VolumeManager.write_file(volume_name, path, content) do
            :ok -> {:ok, "Wrote #{byte_size(content)} bytes to #{path}"}
            {:error, reason} -> {:error, "Failed to write file: #{reason}"}
          end

        _ ->
          {:error, "Agent #{agent_id} has no workspace"}
      end
    end
  end

  def do_read_file(agent_id, path) do
    if String.contains?(path, "..") do
      {:error, "Path cannot contain '..'"}
    else
      case BoomLooper.ChatAgent.get_state(agent_id) do
        %{workspace_id: workspace_id} when is_binary(workspace_id) ->
          volume_name = BoomLooper.Workspace.volume_name_for(workspace_id)
          BoomLooper.VolumeManager.read_file(volume_name, path)

        _ ->
          {:error, "Agent #{agent_id} has no workspace"}
      end
    end
  end

  def do_docker(command, timeout_seconds) do
    # Parse command string into args
    args = String.split(command, ~r/\s+/, trim: true)

    Docker.docker(args, timeout: timeout_seconds * 1_000)
  end

  def do_docker_compose(agent_id, command, timeout_seconds) do
    case BoomLooper.ChatAgent.get_state(agent_id) do
      %{workspace_id: workspace_id} when is_binary(workspace_id) ->
        project_dir = Path.join([BoomLooper.Workspace.home_dir(), "workspaces", workspace_id])
        volume_name = BoomLooper.Workspace.volume_name_for(workspace_id)

        # Sync files from volume to host before running docker-compose
        # Agent writes to volume, but docker-compose runs on host
        sync_volume_to_host(volume_name, project_dir)

        compose_file = BoomLooper.Compose.compose_path(project_dir)
        project_name = BoomLooper.Compose.project_name(workspace_id)

        # Parse command string into args
        args = String.split(command, ~r/\s+/, trim: true)
        full_args = ["-f", compose_file, "-p", project_name | args]

        BoomLooper.Compose.compose_cmd(full_args, timeout_seconds * 1_000)

      _ ->
        {:error, "Agent #{agent_id} has no workspace"}
    end
  end

  # Sync .boomlooper/workspace/ from volume to host filesystem
  # This bridges the gap between agent writes (inside volume) and docker-compose (needs host paths)
  defp sync_volume_to_host(volume_name, project_dir) do
    host_dir = Path.join(project_dir, ".boomlooper/workspace")
    File.mkdir_p!(host_dir)

    # Sync Dockerfile (no substitution needed)
    case BoomLooper.VolumeManager.read_file(volume_name, ".boomlooper/workspace/Dockerfile") do
      {:ok, content} -> File.write!(Path.join(host_dir, "Dockerfile"), content)
      {:error, _} -> :ok
    end

    # Sync docker-compose.yml with variable substitution
    case BoomLooper.VolumeManager.read_file(volume_name, ".boomlooper/workspace/docker-compose.yml") do
      {:ok, content} ->
        # Substitute variables that agents use in their compose files
        # ${CODE_VOLUME} -> actual volume name
        # /workspace context -> host path (for Dockerfile access)
        processed = content
          |> String.replace("${CODE_VOLUME}", volume_name)
          |> String.replace(~r/context:\s*\/workspace/, "context: #{host_dir}")
        File.write!(Path.join(host_dir, "docker-compose.yml"), processed)
      {:error, _} ->
        :ok
    end

    :ok
  end

  def do_workspace_info(agent_id) do
    case BoomLooper.ChatAgent.get_state(agent_id) do
      %{workspace_id: workspace_id} = state when is_binary(workspace_id) ->
        volume_name = BoomLooper.Workspace.volume_name_for(workspace_id)
        project_dir = Path.join([BoomLooper.Workspace.home_dir(), "workspaces", workspace_id])
        compose_project = BoomLooper.Compose.project_name(workspace_id)

        info = %{
          workspace_id: workspace_id,
          volume_name: volume_name,
          project_dir: project_dir,
          compose_project: compose_project,
          compose_file: ".boomlooper/workspace/docker-compose.yml",
          dockerfile: ".boomlooper/workspace/Dockerfile",
          workspace_container: "#{compose_project}-workspace-1",
          working_dir: state[:working_dir],
          bind_mount: state[:bind_mount]
        }

        {:ok, Jason.encode!(info, pretty: true)}

      _ ->
        {:error, "Agent #{agent_id} has no workspace"}
    end
  end

  def do_volumes(agent_id, action) do
    case BoomLooper.ChatAgent.get_state(agent_id) do
      %{workspace_id: workspace_id} when is_binary(workspace_id) ->
        case parse_volume_action(action) do
          {:list} ->
            case BoomLooper.VolumeManager.list_workspace_volumes(workspace_id) do
              {:ok, volumes} -> {:ok, Jason.encode!(volumes, pretty: true)}
              {:error, reason} -> {:error, reason}
            end

          {:ls, volume_name, path} ->
            BoomLooper.VolumeManager.volume_ls(volume_name, path)

          {:info, volume_name} ->
            case BoomLooper.VolumeManager.volume_info(volume_name) do
              nil -> {:error, "Volume not found: #{volume_name}"}
              info -> {:ok, Jason.encode!(info, pretty: true)}
            end
        end

      _ ->
        {:error, "Agent #{agent_id} has no workspace"}
    end
  end

  defp parse_volume_action(action) do
    case String.split(String.trim(action), ~r/\s+/, parts: 3) do
      ["list"] -> {:list}
      ["ls", volume] -> {:ls, volume, "/"}
      ["ls", volume, path] -> {:ls, volume, path}
      ["info", volume] -> {:info, volume}
      _ -> {:list}  # default
    end
  end

  def do_service_containers(agent_id) do
    case BoomLooper.ChatAgent.get_state(agent_id) do
      %{workspace_id: workspace_id} when is_binary(workspace_id) ->
        prefix = "bl-#{workspace_id}"

        case Docker.docker(["ps", "-a", "--filter", "name=#{prefix}",
                            "--format", "{{.Names}}\t{{.Status}}\t{{.Ports}}"]) do
          {:ok, ""} ->
            {:ok, "No containers found for this workspace."}

          {:ok, output} ->
            {:ok, output}

          {:error, reason} ->
            {:error, "Failed to list containers: #{reason}"}
        end

      _ ->
        {:error, "Agent #{agent_id} has no workspace"}
    end
  end

  def do_exec_stream(agent_id, command, timeout_seconds) do
    case resolve_container(agent_id) do
      {:ok, container} ->
        # Create the stream message via ChatAgent API (not direct ETS writes)
        stream_msg = %{role: :build, title: command, content: "", timestamp: DateTime.utc_now()}
        stream_msg = BoomLooper.ChatAgent.append_message_ets(agent_id, stream_msg)
        msg_id = if stream_msg, do: stream_msg.id, else: :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)

        # Run in background Task
        Task.start(fn ->
          port = Port.open(
            {:spawn_executable, System.find_executable("docker")},
            [:binary, :exit_status, {:args, ["exec", container, "sh", "-c", command]}]
          )

          stream_port_output(agent_id, port, command, msg_id, "", timeout_seconds * 1_000)
        end)

        {:ok, "Streaming command started: #{command}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stream_port_output(agent_id, port, command, msg_id, acc, timeout) do
    receive do
      {^port, {:data, data}} ->
        acc = acc <> data

        # Update message content in ETS
        BoomLooper.ChatAgent.update_message(agent_id, msg_id, fn msg ->
          %{msg | content: acc}
        end)

        # Broadcast to LiveView — include msg_id so the LiveView uses the same ID
        Phoenix.PubSub.broadcast(BoomLooper.PubSub,
          "chat_agent:#{agent_id}",
          {:stream_output, agent_id, data, command, msg_id})

        stream_port_output(agent_id, port, command, msg_id, acc, timeout)

      {^port, {:exit_status, code}} ->
        # Mark as done in ETS
        BoomLooper.ChatAgent.update_message(agent_id, msg_id, fn msg ->
          %{msg | role: :build_done, content: acc}
        end)

        status = if code == 0, do: "completed", else: "exited (code #{code})"
        Phoenix.PubSub.broadcast(BoomLooper.PubSub,
          "chat_agent:#{agent_id}",
          {:chat_message, agent_id, %{role: :system, content: "Command #{status}", timestamp: DateTime.utc_now()}})
    after
      timeout ->
        Port.close(port)
        BoomLooper.ChatAgent.update_message(agent_id, msg_id, fn msg ->
          %{msg | role: :build_failed, content: acc}
        end)
        Phoenix.PubSub.broadcast(BoomLooper.PubSub,
          "chat_agent:#{agent_id}",
          {:chat_message, agent_id, %{role: :system, content: "Command timed out after #{div(timeout, 1_000)}s", timestamp: DateTime.utc_now()}})
    end
  end

  # --- Private ---

  # All agents exec into the compose "workspace" service
  defp resolve_container(agent_id) do
    case BoomLooper.ChatAgent.get_state(agent_id) do
      %{workspace_id: workspace_id} when is_binary(workspace_id) ->
        container = ServiceManager.service_container_name(workspace_id, "workspace")
        {:ok, container}

      _ ->
        {:error, "Agent #{agent_id} has no workspace"}
    end
  end

  # Resolve a specific service container by compose service name
  defp resolve_service_container(agent_id, service_name) do
    case BoomLooper.ChatAgent.get_state(agent_id) do
      %{workspace_id: workspace_id} when is_binary(workspace_id) ->
        container = ServiceManager.service_container_name(workspace_id, service_name)

        if Docker.container_running?(container) || container_exists?(container) do
          {:ok, container}
        else
          {:error, "Service #{service_name} not found"}
        end

      _ ->
        {:error, "Agent #{agent_id} has no workspace"}
    end
  end

  defp container_exists?(name) do
    match?({:ok, _}, Docker.docker(["inspect", "--format", "{{.Name}}", name]))
  end
end
