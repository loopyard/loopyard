defmodule BoomLooper.Tools.Workspace do
  @moduledoc """
  MCP tools for managing workspace infrastructure.
  Granular tools for Dockerfile, services, processes, and rebuilds.
  The workspace config (.boomlooper/repo/workspace.json) is updated behind the scenes.
  """
  use ClaudeCode.MCP.Server, name: "boom-looper-workspace"

  alias BoomLooper.Workspace
  alias BoomLooper.Workspace.ServiceManager

  # --- Tool definitions ---

  tool :set_dockerfile, "Set or update the Dockerfile for the workspace dev container. After setting, use `rebuild` to apply." do
    field :agent_id, :string, required: true
    field :dockerfile, :string, required: true, description: "Full Dockerfile content"

    def execute(%{agent_id: agent_id, dockerfile: dockerfile}) do
      BoomLooper.Tools.Workspace.do_update_config(agent_id, fn ws ->
        %{ws | dockerfile: dockerfile}
      end, "Dockerfile updated")
    end
  end

  tool :set_dev_command, "Set the dev server command and ports. This runs as a container from the workspace image." do
    field :agent_id, :string, required: true
    field :command, :string, required: true, description: "Command to start the dev server (e.g. bin/dev, foreman start)"
    field :name, :string, required: false, description: "Name for the dev service (default: dev)"
    field :ports, :string, required: false, description: "JSON array of container ports to expose (e.g. [\"3000\"]). Host ports are allocated dynamically — do NOT specify host:container mappings."

    def execute(%{agent_id: agent_id, command: command} = params) do
      name = Map.get(params, :name, "dev")
      ports = BoomLooper.Tools.Workspace.parse_json_field(params[:ports], [])

      BoomLooper.Tools.Workspace.do_update_config(agent_id, fn ws ->
        # Replace any existing process with this name, or add new
        processes = Enum.reject(ws.processes, &(&1.name == name))
        %{ws | processes: processes ++ [%{name: name, command: command, ports: ports}]}
      end, "Dev command set: #{command}")
    end
  end

  tool :add_service, "Add a stock service (e.g. postgres, redis) that runs as its own container. Use {data} in volume specs for a workspace-scoped persistent volume." do
    field :agent_id, :string, required: true
    field :name, :string, required: true, description: "Service name (e.g. postgres, redis)"
    field :image, :string, required: true, description: "Docker image (e.g. postgres:16, pgvector/pgvector:pg16, redis:7)"
    field :env, :string, required: false, description: "JSON object of env vars for the service"
    field :ports, :string, required: false, description: "JSON array of container ports to expose (e.g. [\"5432\"]). Host ports are allocated dynamically."
    field :volumes, :string, required: false, description: "JSON array of volume mounts. Use {data} for persistent workspace-scoped volume (e.g. [\"{data}:/var/lib/postgresql/data\"])"

    def execute(%{agent_id: agent_id, name: name, image: image} = params) do
      env = BoomLooper.Tools.Workspace.parse_json_field(params[:env], %{})
      ports = BoomLooper.Tools.Workspace.parse_json_field(params[:ports], [])
      volumes = BoomLooper.Tools.Workspace.parse_json_field(params[:volumes], [])

      BoomLooper.Tools.Workspace.do_update_config(agent_id, fn ws ->
        services = Enum.reject(ws.services, &(&1.name == name))
        %{ws | services: services ++ [%{name: name, image: image, env: env, volumes: volumes, ports: ports}]}
      end, "Service added: #{name} (#{image})")
    end
  end

  tool :remove_service, "Remove a stock service from the workspace." do
    field :agent_id, :string, required: true
    field :name, :string, required: true, description: "Service name to remove"

    def execute(%{agent_id: agent_id, name: name}) do
      BoomLooper.Tools.Workspace.do_update_config(agent_id, fn ws ->
        %{ws | services: Enum.reject(ws.services, &(&1.name == name)),
               processes: Enum.reject(ws.processes, &(&1.name == name))}
      end, "Service removed: #{name}")
    end
  end

  tool :set_env_vars, "Set environment variables for the workspace container." do
    field :agent_id, :string, required: true
    field :env_vars, :string, required: true, description: "JSON object of env vars (e.g. {\"RAILS_ENV\":\"development\"})"

    def execute(%{agent_id: agent_id, env_vars: env_vars}) do
      parsed = BoomLooper.Tools.Workspace.parse_json_field(env_vars, %{})

      BoomLooper.Tools.Workspace.do_update_config(agent_id, fn ws ->
        %{ws | env_vars: Map.merge(ws.env_vars, parsed)}
      end, "Environment variables updated")
    end
  end

  tool :set_workspace_name, "Set the workspace/project name." do
    field :agent_id, :string, required: true
    field :name, :string, required: true

    def execute(%{agent_id: agent_id, name: name}) do
      BoomLooper.Tools.Workspace.do_update_config(agent_id, fn ws ->
        %{ws | name: name}
      end, "Workspace named: #{name}")
    end
  end

  tool :set_system_prompt, "Set a system prompt fragment that future agents will see when working on this project." do
    field :agent_id, :string, required: true
    field :system_prompt, :string, required: true

    def execute(%{agent_id: agent_id, system_prompt: prompt}) do
      BoomLooper.Tools.Workspace.do_update_config(agent_id, fn ws ->
        %{ws | system_prompt: prompt}
      end, "System prompt updated")
    end
  end

  tool :rebuild, "Rebuild the workspace Docker image and restart containers. Call ONCE after setting Dockerfile, services, and env vars. Do NOT call multiple times — if build fails, read logs, fix the Dockerfile, then rebuild once." do
    field :agent_id, :string, required: true

    def execute(%{agent_id: agent_id}) do
      BoomLooper.Tools.Workspace.do_rebuild(agent_id)
    end
  end

  tool :service_status, "Check which workspace services are running. Call ONCE after rebuild. Do NOT poll in a loop — if services aren't up yet, read logs instead." do
    field :agent_id, :string, required: true

    def execute(%{agent_id: agent_id}) do
      BoomLooper.Tools.Workspace.do_service_status(agent_id)
    end
  end

  # --- Public helpers ---

  @doc false
  def do_update_config(agent_id, update_fn, success_msg) do
    with_workspace_id(agent_id, fn workspace_id ->
      volume_name = "code-#{workspace_id}"

      ws = case Workspace.load_from_volume(volume_name) do
        {:ok, existing} -> existing
        _ -> %Workspace{}
      end

      updated = update_fn.(ws)

      case Workspace.save_to_volume(volume_name, updated) do
        :ok -> {:ok, success_msg}
        {:error, reason} -> {:error, "Failed to save config: #{inspect(reason)}"}
      end
    end)
  end

  @rebuild_table :rebuild_tasks

  def do_rebuild(agent_id) do
    with_bind_mount(agent_id, fn project_dir ->
      workspace_id = find_workspace_id(agent_id)
      volume_name = if workspace_id, do: "code-#{workspace_id}"

      case (if volume_name, do: Workspace.load_from_volume(volume_name), else: Workspace.load(project_dir)) do
        {:ok, ws} when ws.dockerfile != nil ->
          # Cancel any in-progress rebuild for this project
          cancel_previous_rebuild(project_dir, workspace_id)

          # Create a streaming build message in chat
          stream_msg = %{role: :build, title: "Rebuild", content: "", timestamp: DateTime.utc_now()}
          stream_msg = BoomLooper.ChatAgent.append_message_ets(agent_id, stream_msg)
          msg_id = if stream_msg, do: stream_msg.id, else: :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)

          # Run rebuild async with streaming output — track the task so we can cancel it
          {:ok, task_pid} = Task.start(fn ->
            callback = fn chunk ->
              BoomLooper.ChatAgent.update_message(agent_id, msg_id, fn msg ->
                %{msg | content: (msg.content || "") <> chunk}
              end)

              Phoenix.PubSub.broadcast(BoomLooper.PubSub,
                "chat_agent:#{agent_id}",
                {:stream_output, agent_id, chunk, "Rebuild", msg_id})
            end

            # Check if the workspace container is already running.
            # First rebuild after setup: nothing is running, so start everything.
            # Subsequent rebuilds: only rebuild dev containers, keep workspace running.
            ws_id = Workspace.workspace_id(project_dir)
            ws_container = ServiceManager.service_container_name(ws_id, "workspace")
            workspace_running = BoomLooper.Docker.container_running?(ws_container)

            rebuild_result = if workspace_running do
              ServiceManager.restart_dev_streaming(project_dir, callback)
            else
              ServiceManager.restart_workspace_streaming(project_dir, callback)
            end

            case rebuild_result do
              {:ok, _output} ->
                BoomLooper.ChatAgent.update_message(agent_id, msg_id, fn msg ->
                  %{msg | role: :build_done}
                end)

                Phoenix.PubSub.broadcast(BoomLooper.PubSub,
                  "chat_agent:#{agent_id}",
                  {:chat_message, agent_id, %{role: :system, content: "Rebuild complete. Services starting.", timestamp: DateTime.utc_now()}})

                agent_ids = find_workspace_agent_ids(project_dir) -- [agent_id]
                Enum.each(agent_ids, &BoomLooper.ChatAgent.restart_session/1)

              {:error, :arm64_unsupported, _output} ->
                BoomLooper.ChatAgent.update_message(agent_id, msg_id, fn msg ->
                  %{msg | role: :build_failed}
                end)

                arm64_msg = """
                **ARM64 image not available.** One of your service images doesn't have an ARM64 build.

                To fix: Use `remove_service` to remove the incompatible service, then `add_service` with an ARM64-compatible image.

                Common alternatives:
                - PostGIS: `ghcr.io/baosystems/postgis:17-3.5` instead of `postgis/postgis`
                - Check `docker manifest inspect <image>` for architecture support
                """

                Phoenix.PubSub.broadcast(BoomLooper.PubSub,
                  "chat_agent:#{agent_id}",
                  {:chat_message, agent_id, %{role: :system, content: arm64_msg, timestamp: DateTime.utc_now()}})

              {:error, _output} ->
                BoomLooper.ChatAgent.update_message(agent_id, msg_id, fn msg ->
                  %{msg | role: :build_failed}
                end)

                Phoenix.PubSub.broadcast(BoomLooper.PubSub,
                  "chat_agent:#{agent_id}",
                  {:chat_message, agent_id, %{role: :system, content: "Rebuild failed. Check build output above.", timestamp: DateTime.utc_now()}})
            end
          end)

          # Track the rebuild task so we can cancel it if another rebuild starts
          ensure_rebuild_table()
          :ets.insert(@rebuild_table, {project_dir, task_pid})

          {:ok, "Rebuild started. The build runs in the background — you will receive a system message when it completes or fails. Do NOT poll service_status or service_containers while waiting. Proceed to your next configuration step, or wait for the build result."}

        {:ok, _} ->
          {:error, "No Dockerfile set. Use set_dockerfile first."}

        _ ->
          {:error, "No workspace config. Use set_dockerfile to create one."}
      end
    end)
  end

  defp cancel_previous_rebuild(project_dir, workspace_id) do
    ensure_rebuild_table()

    # Kill the previous rebuild task if running
    case :ets.lookup(@rebuild_table, project_dir) do
      [{_, pid}] when is_pid(pid) ->
        if Process.alive?(pid), do: Process.exit(pid, :kill)
        :ets.delete(@rebuild_table, project_dir)
      _ -> :ok
    end

    # Kill any orphaned docker-compose processes for this project
    if workspace_id do
      project_name = BoomLooper.Compose.project_name(workspace_id)
      System.cmd("pkill", ["-f", "docker-compose.*#{project_name}"], stderr_to_stdout: true)
    end
  end

  @doc "Check if a rebuild is currently running for this project."
  def rebuild_in_progress?(project_dir) do
    ensure_rebuild_table()
    case :ets.lookup(@rebuild_table, project_dir) do
      [{_, pid}] when is_pid(pid) -> Process.alive?(pid)
      _ -> false
    end
  end

  defp ensure_rebuild_table do
    case :ets.whereis(@rebuild_table) do
      :undefined ->
        try do
          :ets.new(@rebuild_table, [:set, :public, :named_table])
        catch
          :error, :badarg -> @rebuild_table
        end
      _ -> @rebuild_table
    end
  end

  @status_rate_table :status_rate_limit

  def do_service_status(agent_id) do
    # Rate limit: max 3 calls per 60 seconds per agent
    ensure_rate_table()
    now = System.monotonic_time(:second)

    case :ets.lookup(@status_rate_table, agent_id) do
      [{_, timestamps}] ->
        recent = Enum.filter(timestamps, &(now - &1 < 60))
        if length(recent) >= 3 do
          {:error, "Too many service_status calls (#{length(recent)} in 60s). Do NOT poll in a loop. Call service_status ONCE after rebuild. If services aren't running, use `logs` to diagnose."}
        else
          :ets.insert(@status_rate_table, {agent_id, [now | recent]})
          do_service_status_inner(agent_id)
        end
      [] ->
        :ets.insert(@status_rate_table, {agent_id, [now]})
        do_service_status_inner(agent_id)
    end
  end

  defp do_service_status_inner(agent_id) do
    with_bind_mount(agent_id, fn project_dir ->
      case ServiceManager.service_status(project_dir) do
        {:ok, statuses} -> {:ok, %{services: statuses}}
        other -> other
      end
    end)
  end

  defp ensure_rate_table do
    case :ets.whereis(@status_rate_table) do
      :undefined ->
        try do
          :ets.new(@status_rate_table, [:set, :public, :named_table])
        catch
          :error, :badarg -> @status_rate_table
        end
      _ -> @status_rate_table
    end
  end


  @doc false
  def parse_json_field(nil, default), do: default

  def parse_json_field(value, default) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, parsed} -> parsed
      {:error, _} -> default
    end
  end

  def parse_json_field(value, _default), do: value

  # --- Private ---

  defp with_bind_mount(agent_id, callback) do
    case find_bind_mount(agent_id) do
      {:ok, project_dir} -> callback.(project_dir)
      :error -> {:error, "Agent #{agent_id} has no bind mount"}
    end
  end

  defp with_workspace_id(agent_id, callback) do
    case find_workspace_id(agent_id) do
      nil -> {:error, "Agent #{agent_id} has no workspace"}
      workspace_id -> callback.(workspace_id)
    end
  end

  defp find_bind_mount(agent_id) do
    case BoomLooper.ChatAgent.get_state(agent_id) do
      %{bind_mount: dir} when is_binary(dir) -> {:ok, dir}
      %{working_dir: dir} when is_binary(dir) -> {:ok, dir}
      _ -> :error
    end
  end

  defp find_workspace_id(agent_id) do
    case BoomLooper.ChatAgent.get_state(agent_id) do
      %{workspace_id: ws_id} when is_binary(ws_id) -> ws_id
      _ -> nil
    end
  end

  defp find_workspace_agent_ids(project_dir) do
    BoomLooper.ChatAgent.list_agents()
    |> Enum.filter(fn agent ->
      agent.bind_mount == project_dir && agent.status in [:idle, :thinking]
    end)
    |> Enum.map(& &1.id)
  end
end
