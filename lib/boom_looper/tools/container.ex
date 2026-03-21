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
        exec_opts = if Map.has_key?(opts, :timeout), do: Keyword.put(exec_opts, :timeout, opts.timeout), else: exec_opts

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

  tool :exec, "Run a shell command inside the container. Use timeout for long commands like bundle install." do
    field :agent_id, :string, required: true
    field :command, :string, required: true
    field :workdir, :string, required: false
    field :timeout, :integer, required: false

    def execute(%{agent_id: agent_id, command: command} = params) do
      BoomLooper.Tools.Container.do_exec(agent_id, command, params)
    end
  end

  tool :logs, "View container logs. Pass 'service' to see a specific service's logs (e.g. 'dev', 'postgres')." do
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

  tool :ports, "Show all listening ports in the container" do
    field :agent_id, :string, required: true

    def execute(%{agent_id: agent_id}) do
      BoomLooper.Tools.Container.do_ports(agent_id)
    end
  end

  # --- Private ---

  # All agents exec into the compose "workspace" service
  defp resolve_container(agent_id) do
    case BoomLooper.ChatAgent.get_state(agent_id) do
      %{bind_mount: bm} when is_binary(bm) ->
        workspace_id = BoomLooper.Workspace.workspace_id(bm)
        container = ServiceManager.service_container_name(workspace_id, "workspace")
        {:ok, container}

      _ ->
        {:error, "Agent #{agent_id} has no workspace"}
    end
  end

  # Resolve a specific service container by compose service name
  defp resolve_service_container(agent_id, service_name) do
    case BoomLooper.ChatAgent.get_state(agent_id) do
      %{bind_mount: bm} when is_binary(bm) ->
        workspace_id = BoomLooper.Workspace.workspace_id(bm)
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
