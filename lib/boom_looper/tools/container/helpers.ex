defmodule BoomLooper.Tools.Container.Helpers do
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
  `BoomLooper.Tool` rejects mismatched caller-supplied ids before the
  tool body runs.

  `validate_workspace_path/1` is the filesystem sandbox: every file
  tool normalizes its input path against `/workspace/` and rejects
  anything that escapes it.
  """

  alias BoomLooper.Docker
  alias BoomLooper.Workspace.ServiceManager

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

  def validate_timeout(seconds) when is_number(seconds) and seconds >= 1 and seconds <= 3600, do: :ok
  def validate_timeout(_), do: {:error, "timeout must be between 1 and 3600 seconds"}

  @doc """
  Resolve the agent's own workspace container. The agent_id comes from
  the session-bound MCP assigns (verified upstream); the workspace_id
  is read from the agent's ETS state — never from a tool parameter.
  """
  def resolve_container(agent_id) do
    case BoomLooper.ChatAgent.get_state(agent_id) do
      %{workspace_id: workspace_id} when is_binary(workspace_id) ->
        container = ServiceManager.service_container_name(workspace_id, "workspace")
        {:ok, container}

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

  def agent_workspace_id(agent_id) do
    case BoomLooper.ChatAgent.get_state(agent_id) do
      %{workspace_id: wid} when is_binary(wid) -> {:ok, wid}
      _ -> {:error, "Agent #{agent_id} has no workspace"}
    end
  end

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
  Stream output from a Port to a chat message, broadcasting chunks via PubSub.

  Used by docker_compose and exec_stream tools to show real-time build/command output.
  """
  def stream_port_output(agent_id, port, command, msg_id, acc, timeout) do
    receive do
      {^port, {:data, data}} ->
        acc = acc <> data

        BoomLooper.ChatAgent.update_message(agent_id, msg_id, fn msg ->
          %{msg | content: acc}
        end)

        BoomLooper.Events.ChatAgentMessage.publish(%BoomLooper.Events.ChatAgentMessage.StreamOutput{
          agent_id: agent_id,
          data: data,
          title: command,
          msg_id: msg_id
        })

        stream_port_output(agent_id, port, command, msg_id, acc, timeout)

      {^port, {:exit_status, code}} ->
        BoomLooper.ChatAgent.update_message(agent_id, msg_id, fn msg ->
          %{msg | role: :build_done, content: acc}
        end)

        status = if code == 0, do: "completed", else: "exited (code #{code})"

        BoomLooper.Events.ChatAgentMessage.publish(%BoomLooper.Events.ChatAgentMessage.Message{
          agent_id: agent_id,
          msg: %{role: :system, content: "Command #{status}", timestamp: DateTime.utc_now()}
        })
    after
      timeout ->
        Port.close(port)

        BoomLooper.ChatAgent.update_message(agent_id, msg_id, fn msg ->
          %{msg | role: :build_failed, content: acc}
        end)

        BoomLooper.Events.ChatAgentMessage.publish(%BoomLooper.Events.ChatAgentMessage.Message{
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
  Sync .boomlooper/workspace/ files from a Docker volume to the host filesystem.

  Reads Dockerfile and docker-compose.yml from the volume and writes them to the
  host project directory, processing compose variable substitutions.
  """
  def sync_volume_to_host(volume_name, project_dir) do
    host_dir = Path.join(project_dir, ".boomlooper/workspace")
    File.mkdir_p!(host_dir)
    ws_id = Path.basename(project_dir)

    # Sync Dockerfile (no substitution needed). Missing Dockerfile is
    # unusual — surface it so the user/agent can react rather than
    # hitting a cryptic `docker compose build` error later.
    case BoomLooper.VolumeManager.read_file(volume_name, ".boomlooper/workspace/Dockerfile") do
      {:ok, content} ->
        File.write!(Path.join(host_dir, "Dockerfile"), content)

      {:error, :not_found} ->
        BoomLooper.EventLog.warning("workspace:#{ws_id}",
          "No Dockerfile at .boomlooper/workspace/Dockerfile in the volume. " <>
            "Write one via `write_file` before `docker_compose build`.")

      {:error, reason} ->
        BoomLooper.EventLog.error("workspace:#{ws_id}",
          "Failed to read Dockerfile from volume: #{inspect(reason)}")
    end

    # Sync docker-compose.yml with full processing + sticky ports.
    #
    # If `process_agent_compose/3` rejects the file (host bind mount,
    # privileged, external network, etc.), we do NOT fall back to the
    # raw content. Writing a rejected compose file would let a
    # sandbox-escaping compose reach `docker compose up` from the
    # agent-initiated `docker_compose` tool path, bypassing the
    # validation we just ran. See docs/SECURITY.md.
    case BoomLooper.VolumeManager.read_file(
           volume_name,
           ".boomlooper/workspace/docker-compose.yml"
         ) do
      {:ok, content} ->
        case BoomLooper.Compose.process_agent_compose(content, ws_id) do
          {:ok, processed} ->
            processed =
              String.replace(
                processed,
                ~r/context["\s:]*\/workspace/,
                "context: #{host_dir}"
              )

            File.write!(Path.join(host_dir, "docker-compose.yml"), processed)

          {:error, reason} ->
            BoomLooper.EventLog.error(
              "workspace:#{ws_id}",
              "docker-compose.yml rejected by security validator — cluster " <>
                "command will not run until it's fixed.\n\n#{reason}"
            )

            {:error, reason}
        end

      {:error, :not_found} ->
        BoomLooper.EventLog.warning("workspace:#{ws_id}",
          "No docker-compose.yml at .boomlooper/workspace/docker-compose.yml " <>
            "in the volume. Write one via `write_file` before `docker_compose up`.")

      {:error, reason} ->
        BoomLooper.EventLog.error("workspace:#{ws_id}",
          "Failed to read docker-compose.yml from volume: #{inspect(reason)}")
    end

    :ok
  end
end
