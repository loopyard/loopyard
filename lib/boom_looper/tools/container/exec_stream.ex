defmodule BoomLooper.Tools.Container.ExecStream do
  use BoomLooper.Tool,
    name: "exec_stream",
    description: "Run a long-running command with streaming output (e.g. ping, tail -f, watch). Output streams into the chat. The command runs in the background — you can keep working.",
    busy_words: ["streaming output", "tailing", "watching"],
    params: [
      agent_id: {:string, required: true},
      command: {:string, required: true},
      timeout: {:integer, description: "Max seconds to run (default: 30)"}
    ]

  alias BoomLooper.Tools.Container.Helpers

  def execute(%{agent_id: agent_id, command: command} = params, _assigns) do
    timeout_seconds = Map.get(params, :timeout, 30)

    case Helpers.resolve_container(agent_id) do
      {:ok, container} ->
        # Create the stream message via ChatAgent API (not direct ETS writes)
        stream_msg = %{role: :build, title: command, content: "", timestamp: DateTime.utc_now()}
        stream_msg = BoomLooper.ChatAgent.append_message_ets(agent_id, stream_msg)

        msg_id =
          if stream_msg,
            do: stream_msg.id,
            else: :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)

        # Run in background Task
        Task.Supervisor.start_child(BoomLooper.TaskSupervisor, fn ->
          port =
            Port.open(
              {:spawn_executable, System.find_executable("docker")},
              [:binary, :exit_status, {:args, ["exec", container, "sh", "-c", command]}]
            )

          Helpers.stream_port_output(agent_id, port, command, msg_id, "", timeout_seconds * 1_000)
        end)

        {:ok, "Streaming command started: #{command}"}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
