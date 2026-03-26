defmodule BoomLooper.AgentBoot do
  @moduledoc """
  Shared agent boot logic used by both the LiveView and the System API.
  Handles service startup, checklist setup, and sending the initial message.
  """
  require Logger

  alias BoomLooper.ChatAgent
  alias BoomLooper.Workspace

  @doc """
  Boot an agent: start services, optionally set up a checklist, start the Claude session,
  and send the initial message. Call from a Task — this blocks until the session starts.

  Options:
    - :checklist_id — checklist to instantiate
    - :service_name — service to debug
    - :initial_message — override the default first message
  """
  def boot(id, agent_opts, opts \\ []) do
    working_dir = Keyword.fetch!(agent_opts, :working_dir)
    checklist_id = Keyword.get(opts, :checklist_id)
    service_name = Keyword.get(opts, :service_name)
    initial_message = Keyword.get(opts, :initial_message)
    workspace_id = Workspace.workspace_id(working_dir)

    # Load workspace config (nil if no config yet — Setup agent will create it)
    ws_config =
      case Workspace.load(working_dir) do
        {:ok, ws} -> ws
        _ -> nil
      end

    # Start services if workspace container isn't running
    ws_container = Workspace.ServiceManager.service_container_name(workspace_id, "workspace")

    unless BoomLooper.Docker.container_running?(ws_container) do
      ChatAgent.update_boot_status(id, "Starting services...")

      case Workspace.ServiceManager.start_services(working_dir) do
        {:ok, _} -> :ok
        {:error, :service_manager_not_running} -> :ok
        {:error, reason} ->
          ChatAgent.boot_failed(id, reason)
          raise "Service start failed: #{inspect(reason)}"
      end
    end

    # Set up checklist if requested
    ChatAgent.update_boot_status(id, "Starting Claude session...")

    checklist_path =
      if checklist_id do
        ChatAgent.update_boot_status(id, "Setting up checklist...")

        case BoomLooper.Checklist.instantiate_by_id(checklist_id, id, working_dir) do
          {:ok, checklist} -> checklist.active_path
          {:error, _} -> nil
        end
      end

    final_opts =
      if checklist_path, do: agent_opts ++ [checklist_path: checklist_path], else: agent_opts

    # Start the agent GenServer
    ChatAgent.update_boot_status(id, "Starting Claude session...")
    Logger.info("[AgentBoot] #{id} starting Claude session")

    workspace_id = BoomLooper.ProjectRegistry.workspace_id(working_dir)

    case BoomLooper.WorkspaceGroup.start_agent(workspace_id, final_opts) do
      {:ok, _pid} ->
        Logger.info("[AgentBoot] #{id} Claude session started successfully")

        # Send initial message
        msg = initial_message || default_message(ws_config, checklist_path, service_name)

        if msg do
          ChatAgent.send_message(id, msg)
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

  defp default_message(ws_config, checklist_path, service_name) do
    cond do
      checklist_path ->
        "Follow the checklist at /workspace/.boomlooper/workspace/active/#{Path.basename(checklist_path)}. Work through each item in order, using the check_item tool to mark items done as you complete them."

      service_name ->
        "Check the logs for the #{service_name} service and help me debug any issues."

      !ws_config ->
        guide = ChatAgent.setup_guide()
        guide <> "\n\n---\n\nLook at the project in /workspace and help me set up a development environment. Examine the project files to understand what language, framework, and tools are needed."

      true ->
        nil
    end
  end
end
