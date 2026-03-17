defmodule Hive.Tools.Container do
  @moduledoc """
  Tools for managing Docker containers. Agents use these to set up
  dev environments, run commands, and manage web servers.

  The agent handles Docker automatically — creates containers when needed,
  edits Dockerfiles to add dependencies, rebuilds when the env changes.
  """
  use ClaudeCode.MCP.Server, name: "hive-container"

  alias Hive.Docker

  # --- Public API ---

  def do_create(agent_id, opts \\ %{}) do
    dockerfile = Map.get(opts, :dockerfile)
    create_opts = if dockerfile, do: [dockerfile: dockerfile], else: []

    case Docker.create(agent_id, create_opts) do
      {:ok, _} ->
        {:ok, %{
          container: Docker.container_name(agent_id),
          port: Docker.host_port(agent_id),
          workspace: "/workspace"
        }}
      {:error, reason} ->
        {:error, reason}
    end
  end

  def do_exec(agent_id, command) do
    Docker.exec(agent_id, command)
  end

  def do_rebuild(agent_id) do
    case Docker.rebuild(agent_id) do
      {:ok, _} ->
        {:ok, "Container rebuilt from Dockerfile. Port: #{Docker.host_port(agent_id)}"}
      {:error, reason} ->
        {:error, reason}
    end
  end

  def do_stop(agent_id) do
    Docker.stop(agent_id)
    {:ok, "Container stopped"}
  end

  def do_destroy(agent_id) do
    Docker.destroy(agent_id)
    {:ok, "Container and volumes destroyed"}
  end

  def do_logs(agent_id, opts \\ %{}) do
    service = Map.get(opts, :service)
    lines = Map.get(opts, :lines, 100)
    tail_flag = "-n #{lines}"

    # If a specific service is requested, look for its log
    # Otherwise, show all recent log activity
    cmd = cond do
      service ->
        """
        for f in \
          /var/log/#{service}/*.log \
          /var/log/#{service}.log \
          /var/log/syslog; do
          [ -f "$f" ] && echo "=== $f ===" && tail #{tail_flag} "$f" 2>/dev/null
        done
        # Also check journalctl if available
        which journalctl >/dev/null 2>&1 && journalctl -u #{service} #{tail_flag} --no-pager 2>/dev/null || true
        """

      true ->
        """
        echo "=== Recent log activity ==="
        for f in /var/log/*.log /var/log/postgresql/*.log /var/log/mysql/*.log /var/log/redis/*.log /var/log/nginx/*.log; do
          [ -f "$f" ] && echo "--- $f ---" && tail -n 20 "$f" 2>/dev/null
        done
        echo ""
        echo "=== Running processes ==="
        ps aux --no-headers 2>/dev/null | grep -v 'sleep infinity' || ps 2>/dev/null
        echo ""
        echo "=== Listening ports ==="
        ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null || echo "[not available]"
        """
    end

    Docker.exec(agent_id, cmd)
  end

  def do_start_service(agent_id, command, opts \\ %{}) do
    name = Map.get(opts, :name, "service")
    log_file = "/var/log/#{name}.log"

    # Start as a background process, redirect output to log file
    start_cmd = "mkdir -p /var/log && nohup sh -c '#{command}' > #{log_file} 2>&1 & echo $!"

    case Docker.exec(agent_id, start_cmd) do
      {:ok, pid_str} ->
        pid = String.trim(pid_str)
        {:ok, %{pid: pid, name: name, log_file: log_file}}
      {:error, reason} ->
        {:error, reason}
    end
  end

  def do_stop_service(agent_id, opts \\ %{}) do
    cond do
      Map.has_key?(opts, :pid) ->
        Docker.exec(agent_id, "kill #{opts.pid} 2>/dev/null; echo stopped")

      Map.has_key?(opts, :name) ->
        # Find process by name in its log path or command
        Docker.exec(agent_id, "pkill -f '#{opts.name}' 2>/dev/null; echo stopped")

      Map.has_key?(opts, :port) ->
        # Kill whatever is listening on this port
        Docker.exec(agent_id, "fuser -k #{opts.port}/tcp 2>/dev/null; echo stopped")

      true ->
        {:error, "Provide pid, name, or port to identify the service"}
    end
  end

  def do_ports(agent_id) do
    Docker.exec(agent_id, """
    echo "=== Listening ports ==="
    ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null || echo "[not available]"
    echo ""
    echo "=== Mapped host port ==="
    echo "Host port #{Docker.host_port(agent_id)} -> container port 3000"
    """)
  end

  def do_volumes(agent_id) do
    {:ok, %{
      workspace: "/workspace (persists across rebuilds)",
      cache: "/root/.cache (package caches)",
      workspace_volume: Docker.workspace_volume(agent_id),
      cache_volume: Docker.cache_volume(agent_id)
    }}
  end

  def do_inspect(agent_id) do
    checks = [
      {"Dockerfile", "cat /workspace/Dockerfile 2>/dev/null || echo '[none]'"},
      {"Running processes", "ps aux --no-headers 2>/dev/null || ps 2>/dev/null"},
      {"Listening ports", "ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null || echo '[ss/netstat not available]'"},
      {"Installed languages", "for cmd in node python3 ruby go java elixir; do which $cmd 2>/dev/null && $cmd --version 2>&1 | head -1; done"},
      {"Installed databases", "for cmd in psql mysql redis-cli mongosh sqlite3; do which $cmd 2>/dev/null && echo \"  $cmd available\"; done"},
      {"Installed tools", "for cmd in git curl wget make gcc npm yarn pip cargo mix bundle; do which $cmd 2>/dev/null; done"},
      {"Disk usage", "df -h /workspace 2>/dev/null | tail -1"}
    ]

    results =
      Enum.map(checks, fn {label, cmd} ->
        output = case Docker.exec(agent_id, cmd) do
          {:ok, out} -> String.trim(out)
          {:error, _} -> "[error]"
        end
        "## #{label}\n#{output}"
      end)

    {:ok, Enum.join(results, "\n\n")}
  end

  def do_list do
    case System.cmd("docker", ["ps", "--filter", "name=hive-dev", "--format", "{{.Names}}\t{{.Status}}\t{{.Ports}}"],
           stderr_to_stdout: true) do
      {output, 0} ->
        containers =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(fn line ->
            case String.split(line, "\t", parts: 3) do
              [name, status, ports] -> %{name: name, status: status, ports: ports}
              [name, status] -> %{name: name, status: status, ports: ""}
              _ -> %{name: line, status: "unknown", ports: ""}
            end
          end)
        {:ok, containers}
      {output, _} ->
        {:error, "Failed to list: #{String.slice(output, 0, 200)}"}
    end
  end

  # --- Tool definitions ---

  tool :create, "Create a Docker dev environment for this agent. Returns the container name, mapped port, and workspace path." do
    field :agent_id, :string, required: true
    field :dockerfile, :string, required: false

    def execute(%{agent_id: agent_id} = params) do
      Hive.Tools.Container.do_create(agent_id, params)
    end
  end

  tool :exec, "Run a shell command inside the agent's container" do
    field :agent_id, :string, required: true
    field :command, :string, required: true

    def execute(%{agent_id: agent_id, command: command}) do
      Hive.Tools.Container.do_exec(agent_id, command)
    end
  end

  tool :rebuild, "Rebuild the container after editing the Dockerfile in /workspace/Dockerfile. Preserves all files in /workspace." do
    field :agent_id, :string, required: true

    def execute(%{agent_id: agent_id}) do
      Hive.Tools.Container.do_rebuild(agent_id)
    end
  end

  tool :logs, "View log output from services running in the container. Call with no service to see all recent logs, running processes, and listening ports." do
    field :agent_id, :string, required: true
    field :service, :string, required: false
    field :lines, :integer, required: false

    def execute(%{agent_id: agent_id} = params) do
      Hive.Tools.Container.do_logs(agent_id, params)
    end
  end

  tool :inspect_env, "Inspect the container environment: installed languages, databases, tools, running processes, listening ports, and the current Dockerfile" do
    field :agent_id, :string, required: true

    def execute(%{agent_id: agent_id}) do
      Hive.Tools.Container.do_inspect(agent_id)
    end
  end

  tool :start_service, "Start a background service/process in the container. Returns the PID and log file path." do
    field :agent_id, :string, required: true
    field :command, :string, required: true
    field :name, :string, required: true

    def execute(%{agent_id: agent_id, command: command} = params) do
      Hive.Tools.Container.do_start_service(agent_id, command, params)
    end
  end

  tool :stop_service, "Stop a running service by PID, name, or port" do
    field :agent_id, :string, required: true
    field :pid, :string, required: false
    field :name, :string, required: false
    field :port, :integer, required: false

    def execute(%{agent_id: agent_id} = params) do
      Hive.Tools.Container.do_stop_service(agent_id, params)
    end
  end

  tool :ports, "Show all listening ports in the container and the host port mapping" do
    field :agent_id, :string, required: true

    def execute(%{agent_id: agent_id}) do
      Hive.Tools.Container.do_ports(agent_id)
    end
  end

  tool :volumes, "Show volume mounts and what persists across rebuilds" do
    field :agent_id, :string, required: true

    def execute(%{agent_id: agent_id}) do
      Hive.Tools.Container.do_volumes(agent_id)
    end
  end

  tool :stop, "Stop the container (volumes preserved for later)" do
    field :agent_id, :string, required: true

    def execute(%{agent_id: agent_id}) do
      Hive.Tools.Container.do_stop(agent_id)
    end
  end

  tool :destroy, "Destroy container and all volumes permanently" do
    field :agent_id, :string, required: true

    def execute(%{agent_id: agent_id}) do
      Hive.Tools.Container.do_destroy(agent_id)
    end
  end

  tool :list, "List all running Hive containers with their status and ports" do
    def execute(_params) do
      Hive.Tools.Container.do_list()
    end
  end
end
