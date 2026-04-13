defmodule BoomLooper.Tools.Container.Helpers do
  @moduledoc """
  Shared helpers used by multiple container tool modules.
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

  def resolve_container(agent_id) do
    case BoomLooper.ChatAgent.get_state(agent_id) do
      %{workspace_id: workspace_id} when is_binary(workspace_id) ->
        container = ServiceManager.service_container_name(workspace_id, "workspace")
        {:ok, container}

      _ ->
        {:error, "Agent #{agent_id} has no workspace"}
    end
  end

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

        Phoenix.PubSub.broadcast(
          BoomLooper.PubSub,
          "chat_agent:#{agent_id}",
          {:stream_output, agent_id, data, command, msg_id}
        )

        stream_port_output(agent_id, port, command, msg_id, acc, timeout)

      {^port, {:exit_status, code}} ->
        BoomLooper.ChatAgent.update_message(agent_id, msg_id, fn msg ->
          %{msg | role: :build_done, content: acc}
        end)

        status = if code == 0, do: "completed", else: "exited (code #{code})"

        Phoenix.PubSub.broadcast(
          BoomLooper.PubSub,
          "chat_agent:#{agent_id}",
          {:chat_message, agent_id,
           %{role: :system, content: "Command #{status}", timestamp: DateTime.utc_now()}}
        )
    after
      timeout ->
        Port.close(port)

        BoomLooper.ChatAgent.update_message(agent_id, msg_id, fn msg ->
          %{msg | role: :build_failed, content: acc}
        end)

        Phoenix.PubSub.broadcast(
          BoomLooper.PubSub,
          "chat_agent:#{agent_id}",
          {:chat_message, agent_id,
           %{
             role: :system,
             content: "Command timed out after #{div(timeout, 1_000)}s",
             timestamp: DateTime.utc_now()
           }}
        )
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

    # Sync Dockerfile (no substitution needed)
    case BoomLooper.VolumeManager.read_file(volume_name, ".boomlooper/workspace/Dockerfile") do
      {:ok, content} -> File.write!(Path.join(host_dir, "Dockerfile"), content)
      {:error, _} -> :ok
    end

    # Sync docker-compose.yml with full processing + sticky ports
    ws_id = Path.basename(project_dir)
    port_map = BoomLooper.Compose.capture_port_map(ws_id)

    case BoomLooper.VolumeManager.read_file(
           volume_name,
           ".boomlooper/workspace/docker-compose.yml"
         ) do
      {:ok, content} ->
        processed =
          case BoomLooper.Compose.process_agent_compose(content, ws_id, port_map: port_map) do
            {:ok, json} ->
              json

            {:error, _} ->
              content |> String.replace("${CODE_VOLUME}", volume_name)
          end

        processed =
          String.replace(
            processed,
            ~r/context["\s:]*\/workspace/,
            "context: #{host_dir}"
          )

        File.write!(Path.join(host_dir, "docker-compose.yml"), processed)

      {:error, _} ->
        :ok
    end

    :ok
  end
end
