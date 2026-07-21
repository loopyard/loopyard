defmodule Loopyard.Tools.Container.Helpers do
  @moduledoc """
  Shared helpers used by multiple container tool modules.

  ## Security invariants (see docs/SECURITY.md)

  The resolvers in this module are the **only** sanctioned way a tool
  derives the container or volume it will act on. Tools MUST NOT accept
  a `container_name`, `volume_name`, `workspace_id`, or `project_dir`
  parameter from the agent — they pass the agent's id to one of:

    * `resolve_container/1` — the agent's workspace container.
    * `resolve_service_container/2` — another service in the agent's
      own compose project (verified to exist).
    * `agent_workspace_id/1` — just the workspace id, for callers that
      build their own derived names.

  Each of these reads `workspace_id` from the agent's own ChatAgent
  state (in ETS). An agent cannot cross the boundary by passing a
  different id because the session-bound `agent_id` wrapper in
  `Loopyard.Tool` rejects mismatched caller-supplied ids before the
  tool body runs.

  `validate_workspace_path/1` is the filesystem sandbox: every file
  tool normalizes its input path against `/workspace/` and rejects
  anything that escapes it.
  """

  alias Loopyard.Docker
  alias Loopyard.Workspace.ServiceManager

  @doc """
  Validate that a file path stays within /workspace.
  Rejects path traversal (../), absolute paths outside /workspace,
  and null bytes. Returns {:ok, normalized} or {:error, reason}.
  """
  def validate_workspace_path(path) when is_binary(path) do
    cond do
      String.contains?(path, <<0>>) ->
        {:error, "Path contains null bytes"}

      true ->
        normalized = Path.expand(path, "/workspace")

        if String.starts_with?(normalized, "/workspace/") or normalized == "/workspace" do
          {:ok, normalized}
        else
          {:error, "Path must be within /workspace: #{path}"}
        end
    end
  end

  def validate_workspace_path(_), do: {:error, "Path must be a string"}

  def validate_string(value, field, max_bytes) do
    cond do
      not is_binary(value) -> {:error, "#{field} must be a string"}
      byte_size(value) > max_bytes -> {:error, "#{field} exceeds #{max_bytes} byte limit"}
      String.contains?(value, <<0>>) -> {:error, "#{field} contains null bytes"}
      true -> :ok
    end
  end

  def validate_timeout(seconds) when is_number(seconds) and seconds >= 1 and seconds <= 3600,
    do: :ok

  def validate_timeout(_), do: {:error, "timeout must be between 1 and 3600 seconds"}

  @doc """
  Resolve the agent's own workspace container. The agent_id comes from
  the session-bound MCP assigns (verified upstream); the workspace_id
  is read from the agent's ETS state — never from a tool parameter.
  """
  def resolve_container(agent_id) do
    case Loopyard.ChatAgent.get_state(agent_id) do
      # An agent bound directly to a container (the operator, in its workstation
      # image) — its tools run inside THAT container, not a workspace work
      # container. Ensure it's up so tools self-heal.
      %{container: container} when is_binary(container) ->
        if Docker.container_running?(container) do
          {:ok, container}
        else
          # Self-heal: the operator's workstation container stopped — bring it up.
          case Loopyard.Workstation.Container.ensure_up(container_identity(container)) do
            {:ok, c} -> {:ok, c}
            _ -> {:error, "Operator container #{container} is not running"}
          end
        end

      %{workspace_id: workspace_id} when is_binary(workspace_id) ->
        # "Working is the default" (north-star D10): prefer whatever code-mounted
        # container is up — the full compose `workspace` service if the preview
        # cluster is running, otherwise the cheap `WorkContainer`. If neither is
        # up yet, lazily bring the cheap one up so tools self-heal instead of
        # failing. We never boot the dev/preview cluster just to run a tool.
        case Loopyard.Workspace.agent_container(workspace_id) do
          {:ok, container} -> {:ok, container}
          {:error, :not_working} -> Loopyard.Workspace.ensure_working(workspace_id)
        end

      _ ->
        {:error, "Agent #{agent_id} has no workspace"}
    end
  end

  @doc """
  Resolve a named service container within the agent's own compose
  project. The service name is an agent-supplied param, but it's
  combined with the agent's own workspace_id — an agent cannot reach
  a service belonging to another workspace.
  """
  def resolve_service_container(agent_id, service_name) do
    case Loopyard.ChatAgent.get_state(agent_id) do
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

  def agent_workspace_id(agent_id) do
    case Loopyard.ChatAgent.get_state(agent_id) do
      %{workspace_id: wid} when is_binary(wid) -> {:ok, wid}
      _ -> {:error, "Agent #{agent_id} has no workspace"}
    end
  end

  # Workstation identity from its container name (`loopyard-ws-<id>` → `<id>`).
  defp container_identity(container), do: String.replace_prefix(container, "loopyard-ws-", "")

  def normalize_search_path("."), do: "."
  def normalize_search_path(""), do: "."

  def normalize_search_path(path) when is_binary(path) do
    path
    |> String.trim_leading("/")
    |> String.trim_leading("./")
  end

  def shell_quote(s) when is_binary(s) do
    "'" <> String.replace(s, "'", "'\"'\"'") <> "'"
  end

  defp container_exists?(name) do
    match?({:ok, _}, Docker.docker(["inspect", "--format", "{{.Name}}", name]))
  end

  @doc """
  Truncate tool output for the agent's context window.

  The full output stays in the chat (streaming messages, build logs).
  The agent only gets a summary + tail so it can decide what to do
  without burning thousands of tokens on build noise.
  """
  @max_agent_output 8_000

  def truncate_for_agent(output, opts \\ []) do
    max = Keyword.get(opts, :max, @max_agent_output)
    tail_lines = Keyword.get(opts, :tail, 80)

    if byte_size(output) <= max do
      output
    else
      tail = output |> String.split("\n") |> Enum.take(-tail_lines) |> Enum.join("\n")
      "... (#{byte_size(output)} bytes total, showing last #{tail_lines} lines)\n\n#{tail}"
    end
  end

  @doc """
  Drain a BURST of port output: the chunk in hand plus everything that
  arrives within `window_ms`. The streaming loops (exec / docker_compose /
  stream_port_output) do one message-update + one broadcast per burst
  instead of per chunk — a chatty build (watcher spew, line-buffered
  output) published per line, forcing every viewer through a full update
  cycle each time (measured as 100ms+ main-thread stalls while typing).
  ≤100ms of display latency on build output is imperceptible.

  If the port exits mid-drain, the exit message is RE-INJECTED into the
  caller's mailbox so its normal `{:exit_status, _}` branch still runs.
  """
  def drain_port_burst(port, first_data, window_ms \\ 100) do
    deadline = System.monotonic_time(:millisecond) + window_ms
    drain_port_loop(port, first_data, deadline)
  end

  defp drain_port_loop(port, acc, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      acc
    else
      receive do
        {^port, {:data, d}} ->
          drain_port_loop(port, acc <> d, deadline)

        {^port, {:exit_status, _}} = exit_msg ->
          send(self(), exit_msg)
          acc
      after
        remaining -> acc
      end
    end
  end

  @doc """
  Stream output from a Port to a chat message, broadcasting chunks via PubSub.

  Used by docker_compose and exec tools to show real-time build/command output.
  """
  def stream_port_output(agent_id, port, command, msg_id, acc, timeout) do
    receive do
      {^port, {:data, data}} ->
        data = drain_port_burst(port, data)
        acc = acc <> data

        Loopyard.ChatAgent.update_message(agent_id, msg_id, fn msg ->
          %{msg | content: acc}
        end)

        Loopyard.Events.ChatAgentMessage.publish(%Loopyard.Events.ChatAgentMessage.StreamOutput{
          agent_id: agent_id,
          data: data,
          title: command,
          msg_id: msg_id
        })

        stream_port_output(agent_id, port, command, msg_id, acc, timeout)

      {^port, {:exit_status, code}} ->
        Loopyard.ChatAgent.update_message(agent_id, msg_id, fn msg ->
          %{msg | role: :build_done, content: acc}
        end)

        status = if code == 0, do: "completed", else: "exited (code #{code})"

        Loopyard.Events.ChatAgentMessage.publish(%Loopyard.Events.ChatAgentMessage.Message{
          agent_id: agent_id,
          msg: %{role: :system, content: "Command #{status}", timestamp: DateTime.utc_now()}
        })
    after
      timeout ->
        Port.close(port)

        Loopyard.ChatAgent.update_message(agent_id, msg_id, fn msg ->
          %{msg | role: :build_failed, content: acc}
        end)

        Loopyard.Events.ChatAgentMessage.publish(%Loopyard.Events.ChatAgentMessage.Message{
          agent_id: agent_id,
          msg: %{
            role: :system,
            content: "Command timed out after #{div(timeout, 1_000)}s",
            timestamp: DateTime.utc_now()
          }
        })
    end
  end

  @doc """
  Sync .loopyard/workspace/ files from a Docker volume to the host filesystem.

  Reads Dockerfile and docker-compose.yml from the volume and writes them to the
  host project directory, processing compose variable substitutions.
  """
  def sync_volume_to_host(volume_name, project_dir) do
    host_dir = Path.join(project_dir, ".loopyard/workspace")
    File.mkdir_p!(host_dir)
    ws_id = Path.basename(project_dir)

    # Sync Dockerfile (no substitution needed). Missing Dockerfile is
    # unusual — surface it so the user/agent can react rather than
    # hitting a cryptic `docker compose build` error later.
    case Loopyard.VolumeManager.read_file(volume_name, ".loopyard/workspace/Dockerfile") do
      {:ok, content} ->
        File.write!(Path.join(host_dir, "Dockerfile"), content)

      {:error, :not_found} ->
        Loopyard.EventLog.warning(
          "workspace:#{ws_id}",
          "No Dockerfile at .loopyard/workspace/Dockerfile in the volume. " <>
            "Write one via `write_file` before `docker_compose build`."
        )

      {:error, reason} ->
        Loopyard.EventLog.error(
          "workspace:#{ws_id}",
          "Failed to read Dockerfile from volume: #{inspect(reason)}"
        )
    end

    # Sync docker-compose.yml with full processing + sticky ports.
    #
    # If `process_agent_compose/3` rejects the file (host bind mount,
    # privileged, external network, etc.), we do NOT fall back to the
    # raw content. Writing a rejected compose file would let a
    # sandbox-escaping compose reach `docker compose up` from the
    # agent-initiated `docker_compose` tool path, bypassing the
    # validation we just ran. See docs/SECURITY.md.
    case Loopyard.VolumeManager.read_file(
           volume_name,
           ".loopyard/workspace/docker-compose.yml"
         ) do
      {:ok, content} ->
        case Loopyard.Compose.process_agent_compose(content, ws_id) do
          {:ok, processed} ->
            processed =
              String.replace(
                processed,
                ~r/context["\s:]*\/workspace/,
                "context: #{host_dir}"
              )

            File.write!(Path.join(host_dir, "docker-compose.yml"), processed)

          {:error, reason} ->
            Loopyard.EventLog.error(
              "workspace:#{ws_id}",
              "docker-compose.yml rejected by security validator — cluster " <>
                "command will not run until it's fixed.\n\n#{reason}"
            )

            {:error, reason}
        end

      {:error, :not_found} ->
        Loopyard.EventLog.warning(
          "workspace:#{ws_id}",
          "No docker-compose.yml at .loopyard/workspace/docker-compose.yml " <>
            "in the volume. Write one via `write_file` before `docker_compose up`."
        )

      {:error, reason} ->
        Loopyard.EventLog.error(
          "workspace:#{ws_id}",
          "Failed to read docker-compose.yml from volume: #{inspect(reason)}"
        )
    end

    :ok
  end
end
