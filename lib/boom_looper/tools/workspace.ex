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
    field :ports, :string, required: false, description: "JSON array of port mappings (e.g. [\"3000:3000\"])"

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
    field :ports, :string, required: false, description: "JSON array of port mappings (e.g. [\"5432\"])"
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

  tool :rebuild, "Rebuild the workspace Docker image and restart the workspace container. Use after changing the Dockerfile." do
    field :agent_id, :string, required: true

    def execute(%{agent_id: agent_id}) do
      BoomLooper.Tools.Workspace.do_rebuild(agent_id)
    end
  end

  tool :service_status, "Check which workspace services are running." do
    field :agent_id, :string, required: true

    def execute(%{agent_id: agent_id}) do
      BoomLooper.Tools.Workspace.do_service_status(agent_id)
    end
  end

  # --- Public helpers ---

  @doc false
  def do_update_config(agent_id, update_fn, success_msg) do
    with_bind_mount(agent_id, fn project_dir ->
      ws = case Workspace.load(project_dir) do
        {:ok, existing} -> existing
        _ -> %Workspace{}
      end

      updated = update_fn.(ws)

      case Workspace.save(project_dir, updated) do
        :ok -> {:ok, success_msg}
        {:error, reason} -> {:error, "Failed to save config: #{inspect(reason)}"}
      end
    end)
  end

  def do_rebuild(agent_id) do
    with_bind_mount(agent_id, fn project_dir ->
      case Workspace.load(project_dir) do
        {:ok, ws} when ws.dockerfile != nil ->
          workspace_id = Workspace.workspace_id(project_dir)

          # Run rebuild async — compose build + up
          Task.start(fn ->
            # First generate the compose file
            BoomLooper.Compose.write(project_dir, workspace_id)

            Phoenix.PubSub.broadcast(BoomLooper.PubSub,
              "chat_agent:#{agent_id}",
              {:chat_message, agent_id, %{role: :system, content: "Rebuilding services...", timestamp: DateTime.utc_now()}})

            case ServiceManager.restart_workspace_container(project_dir) do
              :ok ->
                Phoenix.PubSub.broadcast(BoomLooper.PubSub,
                  "chat_agent:#{agent_id}",
                  {:chat_message, agent_id, %{role: :system, content: "Rebuild complete. Services restarting.", timestamp: DateTime.utc_now()}})

                agent_ids = find_workspace_agent_ids(project_dir) -- [agent_id]
                Enum.each(agent_ids, &BoomLooper.ChatAgent.restart_session/1)

              {:error, reason} ->
                content = to_string(reason)
                Phoenix.PubSub.broadcast(BoomLooper.PubSub,
                  "chat_agent:#{agent_id}",
                  {:chat_message, agent_id, %{role: :build_failed, content: content, title: "Rebuild", timestamp: DateTime.utc_now()}})
            end
          end)

          {:ok, "Rebuild started."}

        {:ok, _} ->
          {:error, "No Dockerfile set. Use set_dockerfile first."}

        _ ->
          {:error, "No workspace config. Use set_dockerfile to create one."}
      end
    end)
  end

  def do_service_status(agent_id) do
    with_bind_mount(agent_id, fn project_dir ->
      case ServiceManager.service_status(project_dir) do
        {:ok, statuses} -> {:ok, %{services: statuses}}
        other -> other
      end
    end)
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

  defp find_bind_mount(agent_id) do
    case BoomLooper.ChatAgent.get_state(agent_id) do
      %{bind_mount: dir} when is_binary(dir) -> {:ok, dir}
      %{working_dir: dir} when is_binary(dir) -> {:ok, dir}
      _ -> :error
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
