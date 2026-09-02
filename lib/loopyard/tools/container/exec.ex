defmodule Loopyard.Tools.Container.Exec do
  use Loopyard.Tool,
    name: "exec",
    description:
      "Run a shell command inside the container. Use timeout for long-running commands (dependency installs, builds, etc.).",
    busy_words: ["running a command", "executing", "shelling out"],
    params: [
      agent_id: {:string, required: true},
      command: {:string, required: true},
      workdir: :string,
      timeout: {:integer, description: "Max seconds to run (default: 120)"}
    ]

  alias Loopyard.Tools.Container.Helpers

  def execute(%{agent_id: agent_id, command: command} = params, _assigns) do
    timeout = Map.get(params, :timeout, 120)

    with :ok <- Helpers.validate_string(command, "command", 10_000),
         :ok <- Helpers.validate_timeout(timeout),
         {:ok, container} <- Helpers.resolve_container(agent_id),
         :ok <- Helpers.require_docker_daemon() do
      # Stream output to chat so the user sees it live, then return
      # the final result to the agent.
      stream_msg = %{role: :build, title: command, content: "", timestamp: DateTime.utc_now()}
      stream_msg = Loopyard.ChatAgent.append_message_ets(agent_id, stream_msg)

      msg_id =
        if stream_msg,
          do: stream_msg.id,
          else: :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)

      # Login-wrap so the agent's shell sees identity env (credentials sourced
      # from the home volume's ~/.profile) — not injected via `docker run -e`.
      #
      # This tool owns its own Port (interactive streaming needs it), which is
      # exactly why it must honour the daemon gate in the `with` above —
      # `Docker.docker/2` and `Docker.open_port/2` are gated for everyone else
      # (docs/CODE_RULES.md → "Every Docker shell-out honours the daemon gate").
      # The gate sits AFTER container resolution so a workspace-less agent
      # still gets the "no workspace" answer it always did.
      args = ["exec"]
      args = if params[:workdir], do: args ++ ["-w", params.workdir], else: args
      args = args ++ [container, "sh", "-c", Loopyard.Docker.with_login_profile(command)]

      port =
        Port.open(
          {:spawn_executable, System.find_executable("docker")},
          [:binary, :exit_status, {:args, args}]
        )

      {output, exit_code} = collect_output(agent_id, port, command, msg_id, "", timeout * 1_000)
      truncated = Helpers.truncate_for_agent(output)

      if exit_code == 0 do
        {:ok, truncated}
      else
        {:error, truncated}
      end
    end
  end

  defp collect_output(agent_id, port, command, msg_id, acc, timeout) do
    receive do
      {^port, {:data, data}} ->
        # One update + one broadcast per BURST, not per chunk — see
        # Helpers.drain_port_burst/3.
        data = Helpers.drain_port_burst(port, data)
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

        collect_output(agent_id, port, command, msg_id, acc, timeout)

      {^port, {:exit_status, code}} ->
        done_role = if code == 0, do: :build_done, else: :build_failed

        Loopyard.ChatAgent.update_message(agent_id, msg_id, fn msg ->
          # Stamp the real exit code so the console title can finalize to "exit N".
          # Map.put (not `|`) since the build message has no :exit_code key yet.
          %{msg | role: done_role, content: acc} |> Map.put(:exit_code, code)
        end)

        {acc, code}
    after
      timeout ->
        Port.close(port)

        Loopyard.ChatAgent.update_message(agent_id, msg_id, fn msg ->
          %{msg | role: :build_failed, content: acc} |> Map.put(:exit_code, 124)
        end)

        {acc <> "\n[timed out after #{div(timeout, 1_000)}s]", 1}
    end
  end
end
