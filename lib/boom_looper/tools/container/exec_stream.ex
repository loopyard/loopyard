defmodule BoomLooper.Tools.Container.ExecStream do
  @moduledoc false

  alias BoomLooper.Tools.Container.Helpers

  def __tool_name__, do: "exec_stream"

  def __description__,
    do:
      "Run a long-running command with streaming output (e.g. ping, tail -f, watch). Output streams into the chat. The command runs in the background — you can keep working."

  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "agent_id" => %{"type" => "string"},
        "command" => %{"type" => "string"},
        "timeout" => %{"type" => "integer", "description" => "Max seconds to run (default: 30)"}
      },
      "required" => ["agent_id", "command"]
    }
  end

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
        Task.start(fn ->
          port =
            Port.open(
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
end
