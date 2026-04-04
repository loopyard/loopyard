defmodule BoomLooper.EvalRunner do
  @moduledoc """
  Automates eval runs: launch a project, monitor the setup agent,
  record results. Handles max_turns by auto-nudging the agent when
  it goes idle before the checklist is complete.

  All evals run asynchronously under a Task.Supervisor. Use `status/0`
  to check progress and `results/0` to see completed runs.

  Usage via mix boom.rpc:

    mix boom.rpc 'BoomLooper.EvalRunner.run("/path/to/project", clean: true)'
    mix boom.rpc 'BoomLooper.EvalRunner.status()'
  """
  require Logger

  alias BoomLooper.ChatAgent
  alias BoomLooper.ProjectRegistry

  @default_timeout 1_800_000  # 30 minutes
  @poll_interval 5_000       # 5 seconds
  @max_nudges 5              # don't nudge forever

  @doc """
  Run an eval asynchronously. Spawns a supervised task that outlives the
  RPC connection. Use `status/0` to check progress.

  Options:
    - :timeout — max wait time in ms (default: 30 minutes)
    - :poll_interval — how often to check agent state (default: 5s)
    - :max_nudges — max times to nudge an idle agent (default: 5)
    - :clean — remove existing project first (default: false)

  Returns {:ok, pid}.
  """
  def run(project_path, opts \\ []) do
    project_path = Path.expand(project_path)

    {:ok, pid} = Task.Supervisor.start_child(BoomLooper.TaskSupervisor, fn ->
      eval_name = project_path |> Path.basename() |> sanitize_name()
      BoomLooper.StateKeeper.put_eval(eval_name, %{pid: self(), path: project_path, started_at: DateTime.utc_now(), status: :running, result: nil})
      do_run(project_path, opts)
    end)

    {:ok, pid}
  end

  @doc """
  Check status of all running and recent evals.
  """
  def status do
    BoomLooper.StateKeeper.list_evals()
    |> Enum.map(fn {name, info} ->
      running = is_pid(info.pid) and Process.alive?(info.pid)
      %{name: name, status: if(running, do: :running, else: info.status), started_at: info.started_at, result: info[:result]}
    end)
  end

  defp do_run(project_path, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    poll_interval = Keyword.get(opts, :poll_interval, @poll_interval)
    max_nudges = Keyword.get(opts, :max_nudges, @max_nudges)
    clean = Keyword.get(opts, :clean, false)
    project_path = Path.expand(project_path)

    Logger.info("[EvalRunner] Starting eval for #{project_path}")
    started_at = System.monotonic_time(:millisecond)

    # Optionally clean up existing project first
    if clean do
      case ProjectRegistry.list_projects() |> Enum.find(&(&1.path == project_path)) do
        nil -> :ok
        project ->
          Logger.info("[EvalRunner] Cleaning up existing project #{project.id}")

          # Kill all agents for this project
          for agent <- ChatAgent.list_agents(),
              agent[:working_dir] == project_path do
            ChatAgent.stop_agent(agent.id)
            ChatAgent.remove_agent(agent.id)
          end

          # Stop workspace supervisors, tear down containers, wipe all volumes
          workspaces = ProjectRegistry.list_workspaces(project.id)
          Enum.each(workspaces, fn ws ->
            ws_id = BoomLooper.Workspace.workspace_id(ws.path)

            # Stop the workspace supervisor first
            BoomLooper.WorkspaceSupervisor.stop_workspace(ws_id)

            # Tear down containers and compose-managed volumes
            virtual_dir = Path.join([BoomLooper.Workspace.home_dir(), "workspaces", ws_id])
            try do
              BoomLooper.Compose.down_volumes(virtual_dir, ws_id)
            rescue
              _ -> :ok
            catch
              _, _ -> :ok
            end

            # Delete the external code volume (compose won't touch external volumes)
            BoomLooper.VolumeManager.delete_volume("code-#{ws_id}")

            # Delete agents.log so stale agents aren't replayed on restart
            agents_log = Path.join([virtual_dir, ".boomlooper", "workspace", "agents.log"])
            File.rm(agents_log)
          end)

          ProjectRegistry.remove_project(project.id)
          Process.sleep(3_000)
      end
    end

    # Step 1: Add the project
    case ProjectRegistry.add(project_path) do
      {:ok, project, workspace} ->
        # Step 2: Start workspace supervisor
        case BoomLooper.WorkspaceSupervisor.start_workspace(workspace.id, workspace.path) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
        end

        # Step 3: Spawn setup agent
        id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
        name = "Setup"

        ws_id = BoomLooper.Workspace.workspace_id(workspace.path)

        agent_opts = [
          id: id,
          name: name,
          working_dir: workspace.path,
          started_by: "eval_runner",
          bind_mount: workspace.path,
          workspace_id: ws_id
        ]

        ChatAgent.register_booting(id, name, workspace.path)
        Task.start(fn -> BoomLooper.AgentBoot.boot(id, agent_opts) end)

        # Step 4: Poll until done or timeout, with auto-nudging
        deadline = started_at + timeout
        result = poll_agent(id, deadline, poll_interval, project_path, 0, max_nudges)

        # Step 5: Record
        duration_ms = System.monotonic_time(:millisecond) - started_at
        result = Map.merge(result, %{
          project_path: project_path,
          project_name: project.name,
          agent_id: id,
          duration_ms: duration_ms,
          timestamp: DateTime.utc_now()
        })

        record_run(project.name, result)
        Logger.info("[EvalRunner] Eval complete for #{project.name}: #{result.outcome}")

        # Update ETS tracking
        eval_name = sanitize_name(project.name)
        case BoomLooper.StateKeeper.get_eval(eval_name) do
          nil -> :ok
          info -> BoomLooper.StateKeeper.put_eval(eval_name, %{info | status: :done, result: result})
        end

        {:ok, result}

      {:error, reason} ->
        {:error, "Failed to add project: #{reason}"}
    end
  end

  @doc """
  Check if a workspace's services are healthy.
  Returns a map of service name => status.
  """
  def check_services(workspace_path) do
    case BoomLooper.Workspace.ServiceManager.service_status(workspace_path) do
      {:ok, statuses} ->
        Map.new(statuses, fn s -> {s.name, s.status} end)

      _ ->
        %{}
    end
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  @doc """
  Try to fetch an HTTP response from any dev service with a mapped port.
  Returns {:ok, status_code, body_preview} or :no_response.
  """
  def probe_web_service(workspace_path) do
    case BoomLooper.Workspace.ServiceManager.service_status(workspace_path) do
      {:ok, statuses} ->
        statuses
        |> Enum.filter(fn s -> s.type == :process && s.running && s.ports != %{} end)
        |> Enum.find_value(:no_response, fn service ->
          service.ports
          |> Enum.find_value(:no_response, fn {_container_port, host_port} ->
            case http_get("http://localhost:#{host_port}") do
              {:ok, status, body} -> {:ok, status, body}
              :error -> nil
            end
          end)
        end)

      _ ->
        :no_response
    end
  rescue
    _ -> :no_response
  catch
    _, _ -> :no_response
  end

  defp http_get(url) do
    # Use :httpc from stdlib — no deps needed
    :inets.start()
    :ssl.start()

    case :httpc.request(:get, {String.to_charlist(url), []}, [timeout: 5_000, connect_timeout: 3_000], body_format: :binary) do
      {:ok, {{_, status, _}, _headers, body}} ->
        {:ok, status, String.slice(to_string(body), 0..500)}

      _ ->
        :error
    end
  end

  # --- Private ---

  defp poll_agent(agent_id, deadline, interval, project_path, nudges, max_nudges) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      state = ChatAgent.get_state(agent_id)
      # Even on timeout, check if the web service is actually working
      case probe_web_service(project_path) do
        {:ok, status, body} when status in 200..299 ->
          Logger.info("[EvalRunner] Timed out but web service is healthy (HTTP #{status})")
          build_result(:success, state, project_path, nudges, %{http_status: status, http_body_preview: body})
        {:ok, status, body} ->
          build_result(:web_error, state, project_path, nudges, %{http_status: status, http_body_preview: body})
        :no_response ->
          build_result(:timeout, state, project_path, nudges)
      end
    else
      case ChatAgent.get_state(agent_id) do
        nil ->
          Process.sleep(interval)
          poll_agent(agent_id, deadline, interval, project_path, nudges, max_nudges)

        %{status: status} when status in [:booting, :thinking] ->
          Process.sleep(interval)
          poll_agent(agent_id, deadline, interval, project_path, nudges, max_nudges)

        %{status: :idle} = state ->
          if length(state.messages) < 2 do
            # Just started, wait for work to begin
            Process.sleep(interval)
            poll_agent(agent_id, deadline, interval, project_path, nudges, max_nudges)
          else
            # Don't nudge while a rebuild is in progress
            if BoomLooper.Tools.Workspace.rebuild_in_progress?(project_path) do
              Process.sleep(interval)
              poll_agent(agent_id, deadline, interval, project_path, nudges, max_nudges)
            else
              # Check if the web service is actually responding
              case probe_web_service(project_path) do
                {:ok, status, body} when status in 200..299 ->
                  Logger.info("[EvalRunner] Web service healthy (HTTP #{status}), declaring success")
                  build_result(:success, state, project_path, nudges, %{
                    http_status: status,
                    http_body_preview: body
                  })

                {:ok, status, body} ->
                  # Got a response but it's an error — feed it back to the agent
                  Logger.info("[EvalRunner] Web service error (HTTP #{status}), nudging with error body")
                  if nudges >= max_nudges do
                    build_result(:web_error, state, project_path, nudges, %{
                      http_status: status,
                      http_body_preview: body
                    })
                  else
                    nudge_msg = "The web service is returning HTTP #{status}. Here's the response body — fix the issue:\n\n```\n#{body}\n```"
                    ChatAgent.send_message(agent_id, nudge_msg)
                    Process.sleep(interval)
                    poll_agent(agent_id, deadline, interval, project_path, nudges + 1, max_nudges)
                  end

                :no_response ->
                  if nudges >= max_nudges do
                    Logger.warning("[EvalRunner] Agent #{agent_id} idle after #{nudges} nudges, giving up")
                    build_result(:stalled, state, project_path, nudges)
                  else
                    Logger.info("[EvalRunner] Agent #{agent_id} idle, no web response, nudging (#{nudges + 1}/#{max_nudges})")
                    ChatAgent.send_message(agent_id, "The web service is not responding on any port. Check service_status and container logs to debug.")
                    Process.sleep(interval)
                    poll_agent(agent_id, deadline, interval, project_path, nudges + 1, max_nudges)
                  end
              end
            end
          end

        %{status: status} = state when status in [:stopped, :crashed] ->
          build_result(:failed, state, project_path, nudges)

        _other ->
          Process.sleep(interval)
          poll_agent(agent_id, deadline, interval, project_path, nudges, max_nudges)
      end
    end
  end

  defp build_result(outcome, state, project_path, nudges, extra \\ %{}) do
    services = check_services(project_path)
    messages = if state, do: state.messages, else: []

    error_messages =
      messages
      |> Enum.filter(fn m -> m[:role] == :error end)
      |> Enum.map(fn m -> m[:content] end)

    tool_usage =
      messages
      |> Enum.filter(fn m -> m[:role] == :tool end)
      |> Enum.frequencies_by(fn m -> m[:tool] end)

    %{
      outcome: outcome,
      status: state && state[:status],
      message_count: length(messages),
      tool_calls: (state && state[:tool_calls]) || 0,
      errors: length(error_messages),
      error_messages: error_messages,
      services: services,
      nudges: nudges,
      tool_usage: tool_usage
    }
    |> Map.merge(extra)
  end

  @doc """
  Record an eval run to `evals/:project_name/:date.md`.
  """
  def record_run(project_name, result) do
    dir = Path.join(["evals", sanitize_name(project_name), "runs"])
    File.mkdir_p!(dir)

    date = Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d_%H%M%S")
    path = Path.join(dir, "#{date}.md")

    content = format_result(result)
    File.write!(path, content)

    Logger.info("[EvalRunner] Recorded eval to #{path}")
    path
  end

  defp format_result(result) do
    services_section =
      result.services
      |> Enum.map(fn {name, status} -> "- #{name}: #{status}" end)
      |> Enum.join("\n")

    errors_section =
      case result.error_messages do
        [] -> "None"
        errors -> Enum.map_join(errors, "\n", fn e -> "- #{String.slice(to_string(e), 0..200)}" end)
      end

    tools_section =
      result.tool_usage
      |> Enum.sort_by(fn {_k, v} -> -v end)
      |> Enum.map(fn {tool, count} -> "- #{tool}: #{count}" end)
      |> Enum.join("\n")

    """
    # Eval: #{result.project_name}

    - **Date:** #{result.timestamp}
    - **Outcome:** #{result.outcome}
    - **Agent ID:** #{result.agent_id}
    - **Duration:** #{div(result.duration_ms, 1000)}s
    - **Messages:** #{result.message_count}
    - **Tool calls:** #{result.tool_calls}
    - **Errors:** #{result.errors}
    - **Nudges:** #{result.nudges}
    #{if result[:http_status], do: "- **HTTP Status:** #{result.http_status}", else: "- **HTTP Status:** no response"}

    ## Services

    #{services_section}

    ## Tool Usage

    #{tools_section}

    ## Errors

    #{errors_section}
    #{if result[:http_body_preview] do
    """

    ## HTTP Response

    ```
    #{result.http_body_preview}
    ```
    """
    else
      ""
    end}
    ## Project

    #{result.project_path}
    """
  end

  defp sanitize_name(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]/, "_")
    |> String.trim("_")
  end
end
