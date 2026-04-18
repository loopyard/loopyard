defmodule BoomLooper.AgentBoot do
  @moduledoc """
  Shared agent boot logic used by both the LiveView and the System API.
  Handles service startup and sending the initial message.
  """
  require Logger

  alias BoomLooper.ChatAgent
  alias BoomLooper.Workspace

  @doc """
  Boot an agent: start services, start the Claude session, and send the initial message.
  Call from a Task — this blocks until the session starts.

  Options:
    - :service_name — service to debug
    - :initial_message — override the default first message
  """
  def boot(id, agent_opts, opts \\ []) do
    working_dir = Keyword.fetch!(agent_opts, :working_dir)
    service_name = Keyword.get(opts, :service_name)
    initial_message = Keyword.get(opts, :initial_message)
    agent_type = Keyword.get(agent_opts, :agent_type) || BoomLooper.Agents.Registry.default_agent_name()
    # Use workspace_id from opts if provided (volume-based workspaces pass it),
    # otherwise compute from path (bind-mount workspaces)
    workspace_id = Keyword.get(agent_opts, :workspace_id) || Workspace.workspace_id(working_dir)

    # Load workspace config from volume (nil if no config yet)
    # Volume-based workspaces pass the volume name, otherwise compute from workspace_id
    volume_name = Keyword.get(agent_opts, :volume) || "code-#{workspace_id}"
    ws_config =
      case Workspace.load_from_volume(volume_name) do
        {:ok, ws} -> ws
        _ -> nil
      end

    # Start services if workspace container isn't running.
    #
    # For a Setup agent, a compose-up failure is a SOFT error: the
    # whole point of a Setup agent is to fix broken infrastructure.
    # If the user is staring at a workspace whose docker-compose.yml
    # references a Dockerfile that doesn't exist yet, the Setup
    # agent needs to come up so it can write the Dockerfile and
    # retry. Blocking spawn on compose-up deadlocks the flow — the
    # user can't summon the one agent type designed to fix this.
    #
    # For other agent types, a failed compose means there's no
    # container to exec into — boot still fails since the tools
    # won't work. Those errors surface as the same boot-failed
    # message the user saw before.
    ws_container = Workspace.ServiceManager.service_container_name(workspace_id, "workspace")

    unless BoomLooper.Docker.container_running?(ws_container) do
      ChatAgent.update_boot_status(id, "Starting services...")

      case Workspace.ServiceManager.start_services(working_dir) do
        {:ok, _} ->
          :ok

        {:error, :service_manager_not_running} ->
          :ok

        {:error, reason} when agent_type == "setup" ->
          Logger.warning(
            "[AgentBoot] #{id} compose up failed; booting Setup agent anyway so it can fix the cluster: #{inspect(reason)}"
          )

          ChatAgent.update_boot_status(id, "Cluster unhealthy — Setup agent will diagnose")
          :ok

        {:error, reason} ->
          ChatAgent.boot_failed(id, reason)
          raise "Service start failed: #{inspect(reason)}"
      end
    end

    # Start the agent GenServer
    ChatAgent.update_boot_status(id, "Starting Claude session...")
    Logger.info("[AgentBoot] #{id} starting Claude session")

    case BoomLooper.WorkspaceGroup.start_agent(workspace_id, agent_opts) do
      {:ok, _pid} ->
        Logger.info("[AgentBoot] #{id} Claude session started successfully")

        # Send initial message (skip if explicitly :none — blank agents wait for user input)
        unless initial_message == :none do
          msg = initial_message || default_message(agent_type, ws_config, service_name)
          if msg, do: ChatAgent.send_message(id, msg)
        end

        :ok

      {:error, reason} ->
        Logger.error("[AgentBoot] #{id} start_agent failed: #{inspect(reason)}")
        ChatAgent.boot_failed(id, reason)
        {:error, reason}
    end
  rescue
    e ->
      Logger.error("[AgentBoot] #{id} crashed: #{Exception.message(e)}")
      ChatAgent.boot_failed(id, Exception.message(e))
      {:error, Exception.message(e)}
  catch
    :exit, reason ->
      Logger.error("[AgentBoot] #{id} exited: #{inspect(reason)}")
      ChatAgent.boot_failed(id, "Boot process exited: #{inspect(reason)}")
      {:error, reason}
  end

  defp default_message(agent_type, ws_config, service_name) do
    cond do
      service_name ->
        "Check the logs for the #{service_name} service and help me debug any issues."

      agent_type == "setup" ->
        "Look at the project in /workspace and set up a development environment. Start by reading `setup_guide.md` with `read_agent_file` — it has the full playbook. " <>
          "Note: the cluster may not be up yet (compose build can fail if infrastructure files like Dockerfile are missing). Read what's currently in `.boomlooper/workspace/` and fix any gaps before re-running compose."

      ws_config && ws_config.dockerfile ->
        "The workspace has an existing configuration. Check `service_status` — if services are running and healthy, you're good. If not, run `rebuild` then install dependencies via `exec`."

      true ->
        nil
    end
  end
end
