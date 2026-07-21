defmodule Loopyard.Tools.Container.DockerCompose do
  use Loopyard.Tool,
    name: "docker_compose",
    description:
      "Run any docker compose command. Compose file is at .loopyard/workspace/docker-compose.yml",
    busy_words: ["composing", "orchestrating containers", "wrangling Docker"],
    params: [
      agent_id: {:string, required: true},
      command:
        {:string,
         required: true,
         description:
           "Compose command (e.g. 'up -d --build', 'down', 'ps', 'logs dev', 'restart dev')"},
      timeout: {:integer, description: "Max seconds to run (default: 300 for builds)"}
    ]

  alias Loopyard.Tools.Container.Helpers

  alias Loopyard.Tools.Container.Helpers

  def execute(%{agent_id: agent_id, command: command} = params, _assigns) do
    # Default 10 minutes for builds (image pulls can be slow).
    # The agent can override with a shorter timeout for quick commands.
    timeout_seconds = Map.get(params, :timeout, 600)

    case Loopyard.ChatAgent.get_state(agent_id) do
      %{workspace_id: workspace_id} when is_binary(workspace_id) ->
        project_dir = Loopyard.Workspace.compose_dir(workspace_id)
        volume_name = Loopyard.Workspace.volume_name_for(workspace_id)

        # Sync files from volume to host before running docker-compose
        Helpers.sync_volume_to_host(volume_name, project_dir)

        compose_file = Loopyard.Compose.compose_path(project_dir)
        project_name = Loopyard.Compose.project_name(workspace_id)

        args = String.split(command, ~r/\s+/, trim: true)
        full_args = ["-f", compose_file, "-p", project_name | args]

        # Stream build/up to the chat window AND return the result to the
        # agent synchronously. The agent blocks until done — it needs the
        # exit status to know whether to proceed or debug.
        if Enum.any?(args, &(&1 in ~w(up build))) do
          compose_stream(agent_id, full_args, command, timeout_seconds)
        else
          Loopyard.Compose.compose_cmd(full_args, timeout_seconds * 1_000)
        end

      _ ->
        {:error, "Agent #{agent_id} has no workspace"}
    end
  end

  # Run compose synchronously while streaming each output chunk to the
  # chat window via PubSub. Returns {:ok, output} or {:error, output}
  # to the agent when done — the agent sees the full result and can
  # decide what to do next.
  defp compose_stream(agent_id, full_args, command, timeout_seconds) do
    stream_msg = %{
      role: :build,
      title: "docker compose #{command}",
      content: "",
      timestamp: DateTime.utc_now()
    }

    stream_msg = Loopyard.ChatAgent.append_message_ets(agent_id, stream_msg)

    msg_id =
      if stream_msg,
        do: stream_msg.id,
        else: :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)

    docker_path =
      if Loopyard.Compose.docker_compose_v2?() do
        System.find_executable("docker")
      else
        System.find_executable("docker-compose")
      end

    port_args =
      if Loopyard.Compose.docker_compose_v2?() do
        ["compose" | full_args]
      else
        full_args
      end

    port =
      Port.open(
        {:spawn_executable, docker_path},
        [:binary, :exit_status, :stderr_to_stdout, {:args, port_args}]
      )

    # Collect output synchronously, streaming each chunk to the chat
    collect_and_stream(agent_id, port, command, msg_id, "", timeout_seconds * 1_000)
  end

  defp collect_and_stream(agent_id, port, command, msg_id, acc, timeout) do
    receive do
      {^port, {:data, data}} ->
        # One update + one broadcast per BURST, not per chunk — see
        # Helpers.drain_port_burst/3.
        data = Helpers.drain_port_burst(port, data)
        acc = acc <> data

        # Update the streaming message in ETS + broadcast to LiveView
        Loopyard.ChatAgent.update_message(agent_id, msg_id, fn msg ->
          %{msg | content: acc}
        end)

        Loopyard.Events.ChatAgentMessage.publish(%Loopyard.Events.ChatAgentMessage.StreamOutput{
          agent_id: agent_id,
          data: data,
          title: "docker compose #{command}",
          msg_id: msg_id
        })

        collect_and_stream(agent_id, port, command, msg_id, acc, timeout)

      {^port, {:exit_status, 0}} ->
        Loopyard.ChatAgent.update_message(agent_id, msg_id, fn msg ->
          %{msg | role: :build_done, content: acc}
        end)

        # Return only the tail to the agent — the full output is in the
        # streaming message (visible in chat). Don't burn tokens on 100K+
        # of build logs that Claude will never need in full.
        summary = "docker compose #{command} completed successfully"
        {:ok, "#{summary}\n\n#{Helpers.truncate_for_agent(acc, max: 4_000, tail: 50)}"}

      {^port, {:exit_status, code}} ->
        Loopyard.ChatAgent.update_message(agent_id, msg_id, fn msg ->
          %{msg | role: :build_done, content: acc}
        end)

        summary = "docker compose #{command} exited with code #{code}"
        {:error, "#{summary}\n\n#{Helpers.truncate_for_agent(acc, max: 4_000, tail: 50)}"}
    after
      timeout ->
        Port.close(port)
        summary = "docker compose #{command} timed out after #{div(timeout, 1000)}s"
        {:error, "#{summary}\n\n#{Helpers.truncate_for_agent(acc, max: 4_000, tail: 50)}"}
    end
  end
end
