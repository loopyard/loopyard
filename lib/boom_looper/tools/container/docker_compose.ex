defmodule BoomLooper.Tools.Container.DockerCompose do
  use BoomLooper.Tool,
    name: "docker_compose",
    description: "Run any docker compose command. Compose file is at .boomlooper/workspace/docker-compose.yml",
    params: [
      agent_id: {:string, required: true},
      command: {:string, required: true, description: "Compose command (e.g. 'up -d --build', 'down', 'ps', 'logs dev', 'restart dev')"},
      timeout: {:integer, description: "Max seconds to run (default: 300 for builds)"}
    ]

  alias BoomLooper.Tools.Container.Helpers

  def execute(%{agent_id: agent_id, command: command} = params, _assigns) do
    timeout_seconds = Map.get(params, :timeout, 300)

    case BoomLooper.ChatAgent.get_state(agent_id) do
      %{workspace_id: workspace_id} when is_binary(workspace_id) ->
        project_dir = Path.join([BoomLooper.Workspace.home_dir(), "workspaces", workspace_id])
        volume_name = BoomLooper.Workspace.volume_name_for(workspace_id)

        # Sync files from volume to host before running docker-compose
        Helpers.sync_volume_to_host(volume_name, project_dir)

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

    Task.Supervisor.start_child(BoomLooper.TaskSupervisor, fn ->
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

      Helpers.stream_port_output(
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
end
