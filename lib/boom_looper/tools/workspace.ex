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
      end, "Wrote Dockerfile to workspace config. Run `rebuild` to build the image and start containers.")
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
      end, "Wrote dev command `#{command}` to workspace config. This will run in its own container after `rebuild`.")
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
      end, "Added #{name} (#{image}) to workspace config. Container will start after `rebuild`.")
    end
  end

  tool :remove_service, "Remove a stock service from the workspace." do
    field :agent_id, :string, required: true
    field :name, :string, required: true, description: "Service name to remove"

    def execute(%{agent_id: agent_id, name: name}) do
      BoomLooper.Tools.Workspace.do_update_config(agent_id, fn ws ->
        %{ws | services: Enum.reject(ws.services, &(&1.name == name)),
               processes: Enum.reject(ws.processes, &(&1.name == name))}
      end, "Removed #{name} from workspace config. Run `rebuild` to apply.")
    end
  end

  tool :set_env_vars, "Set environment variables for the workspace container." do
    field :agent_id, :string, required: true
    field :env_vars, :string, required: true, description: "JSON object of env vars (e.g. {\"RAILS_ENV\":\"development\"})"

    def execute(%{agent_id: agent_id, env_vars: env_vars}) do
      parsed = BoomLooper.Tools.Workspace.parse_json_field(env_vars, %{})

      BoomLooper.Tools.Workspace.do_update_config(agent_id, fn ws ->
        %{ws | env_vars: Map.merge(ws.env_vars, parsed)}
      end, "Wrote environment variables to workspace config. Applied after `rebuild`.")
    end
  end

  tool :set_workspace_name, "Set the workspace/project name." do
    field :agent_id, :string, required: true
    field :name, :string, required: true

    def execute(%{agent_id: agent_id, name: name}) do
      BoomLooper.Tools.Workspace.do_update_config(agent_id, fn ws ->
        %{ws | name: name}
      end, "Set workspace name to \"#{name}\" in config.")
    end
  end

  tool :set_system_prompt, "Set a system prompt fragment that future agents will see when working on this project." do
    field :agent_id, :string, required: true
    field :system_prompt, :string, required: true

    def execute(%{agent_id: agent_id, system_prompt: prompt}) do
      BoomLooper.Tools.Workspace.do_update_config(agent_id, fn ws ->
        %{ws | system_prompt: prompt}
      end, "Wrote system prompt to workspace config. Future agents will see this.")
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
    workspace_id = find_workspace_id(agent_id)

    if workspace_id do
      # Volume-based: save to Docker volume
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
    else
      # Fallback: save to local bind_mount path (for tests)
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
  end

  @rebuild_table :rebuild_tasks

  def do_rebuild(agent_id) do
    with_bind_mount(agent_id, fn project_dir ->
      workspace_id = find_workspace_id(agent_id)
      volume_name = if workspace_id, do: "code-#{workspace_id}"

      case (if volume_name, do: Workspace.load_from_volume(volume_name), else: Workspace.load(project_dir)) do
        {:ok, ws} when ws.dockerfile != nil ->
          cancel_previous_rebuild(project_dir, workspace_id)

          stream_msg = %{role: :build, title: "Rebuild", content: "", timestamp: DateTime.utc_now()}
          stream_msg = BoomLooper.ChatAgent.append_message_ets(agent_id, stream_msg)
          msg_id = if stream_msg, do: stream_msg.id, else: :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)

          {:ok, task_pid} = Task.start(fn ->
            run_rebuild(agent_id, msg_id, project_dir)
          end)

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

  defp run_rebuild(agent_id, msg_id, project_dir) do
    callback = fn chunk ->
      BoomLooper.ChatAgent.update_message(agent_id, msg_id, fn msg ->
        %{msg | content: (msg.content || "") <> chunk}
      end)

      Phoenix.PubSub.broadcast(BoomLooper.PubSub,
        "chat_agent:#{agent_id}",
        {:stream_output, agent_id, chunk, "Rebuild", msg_id})
    end

    ws_id = Workspace.workspace_id(project_dir)
    ws_container = ServiceManager.service_container_name(ws_id, "workspace")

    rebuild_result = if BoomLooper.Docker.container_running?(ws_container) do
      ServiceManager.restart_dev_streaming(project_dir, callback)
    else
      ServiceManager.restart_workspace_streaming(project_dir, callback)
    end

    handle_rebuild_result(rebuild_result, agent_id, msg_id, project_dir)
  end

  defp handle_rebuild_result({:ok, _output}, agent_id, msg_id, project_dir) do
    BoomLooper.ChatAgent.update_message(agent_id, msg_id, fn msg ->
      %{msg | role: :build_done}
    end)

    # Wait for containers to start, then report actual status
    Process.sleep(5_000)
    status_report = post_rebuild_status(project_dir)
    broadcast_system(agent_id, "Rebuild complete.\n\n#{status_report}")

    agent_ids = find_workspace_agent_ids(project_dir) -- [agent_id]
    Enum.each(agent_ids, &BoomLooper.ChatAgent.restart_session/1)
  end

  defp handle_rebuild_result({:error, :arm64_unsupported, _output}, agent_id, msg_id, _project_dir) do
    BoomLooper.ChatAgent.update_message(agent_id, msg_id, fn msg ->
      %{msg | role: :build_failed}
    end)

    broadcast_system(agent_id, """
    **ARM64 image not available.** One of your service images doesn't have an ARM64 build.

    To fix: Use `remove_service` to remove the incompatible service, then `add_service` with an ARM64-compatible image.

    Common alternatives:
    - PostGIS: `ghcr.io/baosystems/postgis:17-3.5` instead of `postgis/postgis`
    - Check `docker manifest inspect <image>` for architecture support
    """)
  end

  defp handle_rebuild_result({:error, _output}, agent_id, msg_id, _project_dir) do
    BoomLooper.ChatAgent.update_message(agent_id, msg_id, fn msg ->
      %{msg | role: :build_failed}
    end)

    broadcast_system(agent_id, "Rebuild failed. Check build output above.")
  end

  defp broadcast_system(agent_id, content) do
    BoomLooper.ChatAgent.append_message_ets(agent_id, %{
      role: :system,
      content: content,
      timestamp: DateTime.utc_now()
    })
  end

  defp post_rebuild_status(project_dir) do
    ws_id = Workspace.workspace_id(project_dir)

    # Load workspace config to get image names for docs URLs
    ws_config = case Workspace.load_from_volume("code-#{ws_id}") do
      {:ok, ws} -> ws
      _ -> %Workspace{}
    end

    case ServiceManager.service_status(project_dir) do
      {:ok, statuses} ->
        lines = Enum.map(statuses, fn s ->
          port_info = case s.ports do
            ports when is_map(ports) and map_size(ports) > 0 ->
              ports |> Enum.map(fn {cp, hp} -> "#{cp}→localhost:#{hp}" end) |> Enum.join(", ")
            _ -> ""
          end

          status_icon = if s.running, do: "running", else: "NOT RUNNING"
          "- #{s.name}: #{status_icon}#{if port_info != "", do: " (#{port_info})", else: ""}"
        end)

        # Grab logs from ANY crashed/stopped container (processes AND services like postgres)
        crash_logs = statuses
          |> Enum.filter(fn s -> not s.running end)
          |> Enum.map(fn s ->
            container = ServiceManager.service_container_name(ws_id, s.name)
            logs_section = case BoomLooper.Docker.container_logs(container, tail: 50) do
              {:ok, logs} -> "```\n#{String.trim(logs)}\n```"
              _ -> "(no logs available)"
            end

            # Find the image for this service to generate docs URL
            docs_hint = case Enum.find(ws_config.services, &(&1.name == s.name)) do
              %{image: image} -> "\nDocs: #{dockerhub_url(image)}"
              _ -> ""
            end

            "### #{s.name} (crashed)#{docs_hint}\n#{logs_section}"
          end)
          |> Enum.reject(&is_nil/1)

        # Probe HTTP on any running process with ports
        http_report = statuses
          |> Enum.filter(fn s -> s.type == :process and s.running and s.ports != %{} end)
          |> Enum.flat_map(fn s ->
            Enum.map(s.ports, fn {_cp, hp} ->
              case http_probe("http://localhost:#{hp}") do
                {:ok, status, _body} when status in 200..299 ->
                  "HTTP #{status} on port #{hp} — app is working!"
                {:ok, status, body} ->
                  "HTTP #{status} on port #{hp}:\n```\n#{body}\n```"
                :error ->
                  "Port #{hp} mapped but not responding to HTTP yet"
              end
            end)
          end)

        sections = [
          "## Service Status\n#{Enum.join(lines, "\n")}",
          if(crash_logs != [], do: Enum.join(crash_logs, "\n\n"), else: nil),
          if(http_report != [], do: "## HTTP Probe\n#{Enum.join(http_report, "\n")}", else: nil)
        ] |> Enum.reject(&is_nil/1)

        Enum.join(sections, "\n\n")

      _ ->
        "Could not check service status."
    end
  rescue
    _ -> "Could not check service status."
  catch
    _, _ -> "Could not check service status."
  end

  defp http_probe(url) do
    :inets.start()
    :ssl.start()

    case :httpc.request(:get, {String.to_charlist(url), []}, [timeout: 5_000, connect_timeout: 3_000], body_format: :binary) do
      {:ok, {{_, status, _}, _headers, body}} ->
        {:ok, status, String.slice(to_string(body), 0..500)}
      _ ->
        :error
    end
  end

  defp dockerhub_url(image) do
    # Strip tag (e.g. "postgres:16" → "postgres", "pgvector/pgvector:pg16" → "pgvector/pgvector")
    name = image |> String.split(":") |> List.first()

    if String.contains?(name, "/") do
      "https://hub.docker.com/r/#{name}"
    else
      "https://hub.docker.com/_/#{name}"
    end
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
      {:ok, parsed} ->
        parsed

      {:error, _} ->
        # Try parsing KEY=VAL format (comma or newline separated) for env vars
        if String.contains?(value, "=") do
          value
          |> String.split(~r/[,\n]+/)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Map.new(fn pair ->
            case String.split(pair, "=", parts: 2) do
              [k, v] -> {String.trim(k), String.trim(v)}
              _ -> nil
            end
          end)
          |> Map.delete(nil)
        else
          default
        end
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
