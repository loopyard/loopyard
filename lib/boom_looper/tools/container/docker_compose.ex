defmodule BoomLooper.Tools.Container.DockerCompose do
  @moduledoc false

  def __tool_name__, do: "docker_compose"

  def __description__,
    do: "Run any docker compose command. Compose file is at .boomlooper/workspace/docker-compose.yml"

  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "agent_id" => %{"type" => "string"},
        "command" => %{
          "type" => "string",
          "description" =>
            "Compose command (e.g. 'up -d --build', 'down', 'ps', 'logs dev', 'restart dev')"
        },
        "timeout" => %{
          "type" => "integer",
          "description" => "Max seconds to run (default: 300 for builds)"
        }
      },
      "required" => ["agent_id", "command"]
    }
  end

  def execute(%{agent_id: agent_id, command: command} = params, _assigns) do
    timeout_seconds = Map.get(params, :timeout, 300)

    case BoomLooper.ChatAgent.get_state(agent_id) do
      %{workspace_id: workspace_id} when is_binary(workspace_id) ->
        project_dir = Path.join([BoomLooper.Workspace.home_dir(), "workspaces", workspace_id])
        volume_name = BoomLooper.Workspace.volume_name_for(workspace_id)

        # Sync files from volume to host before running docker-compose
        sync_volume_to_host(volume_name, project_dir)

        compose_file = BoomLooper.Compose.compose_path(project_dir)
        project_name = BoomLooper.Compose.project_name(workspace_id)

        args = String.split(command, ~r/\s+/, trim: true)
        full_args = ["-f", compose_file, "-p", project_name | args]

        # Stream build/up commands so the user sees progress in real time.
        if Enum.any?(args, &(&1 in ~w(up build))) do
          compose_stream(agent_id, full_args, command, timeout_seconds)
        else
          BoomLooper.Compose.compose_cmd(full_args, timeout_seconds * 1_000)
        end

      _ ->
        {:error, "Agent #{agent_id} has no workspace"}
    end
  end

  defp compose_stream(agent_id, full_args, command, timeout_seconds) do
    stream_msg = %{
      role: :build,
      title: "docker compose #{command}",
      content: "",
      timestamp: DateTime.utc_now()
    }

    stream_msg = BoomLooper.ChatAgent.append_message_ets(agent_id, stream_msg)

    msg_id =
      if stream_msg,
        do: stream_msg.id,
        else: :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)

    Task.start(fn ->
      docker_path =
        if BoomLooper.Compose.docker_compose_v2?() do
          System.find_executable("docker")
        else
          System.find_executable("docker-compose")
        end

      port_args =
        if BoomLooper.Compose.docker_compose_v2?() do
          ["compose" | full_args]
        else
          full_args
        end

      port =
        Port.open(
          {:spawn_executable, docker_path},
          [:binary, :exit_status, :stderr_to_stdout, {:args, port_args}]
        )

      stream_port_output(
        agent_id,
        port,
        "docker compose #{command}",
        msg_id,
        "",
        timeout_seconds * 1_000
      )
    end)

    {:ok, "Streaming: docker compose #{command}"}
  end

  defp stream_port_output(agent_id, port, command, msg_id, acc, timeout) do
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

  # Sync .boomlooper/workspace/ from volume to host filesystem
  defp sync_volume_to_host(volume_name, project_dir) do
    host_dir = Path.join(project_dir, ".boomlooper/workspace")
    File.mkdir_p!(host_dir)

    # Sync Dockerfile (no substitution needed)
    case BoomLooper.VolumeManager.read_file(volume_name, ".boomlooper/workspace/Dockerfile") do
      {:ok, content} -> File.write!(Path.join(host_dir, "Dockerfile"), content)
      {:error, _} -> :ok
    end

    # Sync docker-compose.yml with full processing
    ws_id = Path.basename(project_dir)

    case BoomLooper.VolumeManager.read_file(
           volume_name,
           ".boomlooper/workspace/docker-compose.yml"
         ) do
      {:ok, content} ->
        processed =
          case BoomLooper.Compose.process_agent_compose(content, ws_id) do
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
