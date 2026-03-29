defmodule BoomLooper.EvalRunner do
  @moduledoc """
  Automates eval runs: launch a project, monitor the setup agent,
  record results. Considers the eval complete when services are healthy
  or when the agent goes idle with no obvious errors.

  Usage from IEx (on the running node or via RPC):

    BoomLooper.EvalRunner.run("/path/to/project")
    BoomLooper.EvalRunner.run("/path/to/project", timeout: 900_000)

  From another machine:

    source .env
    HOME=/tmp MIX_HOME="$PWD/.mix_home" HEX_HOME="$PWD/.hex_home" \\
      elixir --sname eval --cookie "$(cat "$BOOMLOOPER_HOME/cookie")" -e '
      :rpc.call(:"boom@macbook", BoomLooper.EvalRunner, :run, ["/path/to/project"])
      |> IO.inspect()
    '
  """
  require Logger

  alias BoomLooper.ChatAgent
  alias BoomLooper.ProjectRegistry

  @default_timeout 900_000   # 15 minutes
  @poll_interval 5_000       # 5 seconds
  @max_nudges 5              # don't nudge forever

  @doc """
  Run an eval: add the project, spawn a setup agent, wait for completion,
  and record the result. Blocks until done or timeout.

  Options:
    - :timeout — max wait time in ms (default: 15 minutes)
    - :poll_interval — how often to check agent state (default: 5s)
    - :max_nudges — max times to nudge an idle agent (default: 5)
    - :existing — :wipe (remove existing project first) or :keep (default)

  Returns {:ok, result} or {:error, reason}.
  """
  def run(project_path, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    poll_interval = Keyword.get(opts, :poll_interval, @poll_interval)
    max_nudges = Keyword.get(opts, :max_nudges, @max_nudges)
    existing = Keyword.get(opts, :existing, :keep)
    project_path = Path.expand(project_path)

    Logger.info("[EvalRunner] Starting eval for #{project_path}")
    started_at = System.monotonic_time(:millisecond)

    maybe_cleanup(existing, project_path)

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

        agent_opts = [
          id: id,
          name: name,
          working_dir: workspace.path,
          started_by: "eval_runner",
          bind_mount: workspace.path
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
        Map.new(statuses, fn s -> {s.name, s.health} end)

      _ ->
        %{}
    end
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  @doc """
  Verify HTTP response from dev service.
  Returns {:ok, status_code} or {:error, reason}.
  """
  def verify_http_response(workspace_path) do
    workspace_id = BoomLooper.Workspace.workspace_id(workspace_path)

    # Get the dev service port
    case BoomLooper.Compose.ps(workspace_path, workspace_id) do
      {:ok, services} ->
        # Find dev service with a port
        dev_service = Enum.find(services, fn s ->
          s.name == "dev" && map_size(s.ports) > 0
        end)

        case dev_service do
          nil ->
            {:error, "no dev service with exposed ports"}

          %{ports: ports} ->
            {_container_port, host_port} = Enum.at(ports, 0)
            url = "http://localhost:#{host_port}/"

            # Use curl to test HTTP response
            case System.cmd("curl", ["-sS", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "10", url], stderr_to_stdout: true) do
              {status_code, 0} ->
                code = String.trim(status_code) |> String.to_integer()
                if code >= 200 && code < 400 do
                  {:ok, code}
                else
                  {:error, "HTTP #{code}"}
                end

              {error, _} ->
                {:error, "curl failed: #{String.slice(error, 0..100)}"}
            end
        end

      {:error, reason} ->
        {:error, "compose ps failed: #{reason}"}
    end
  rescue
    e -> {:error, "exception: #{inspect(e)}"}
  end

  # --- Private ---

  defp maybe_cleanup(:keep, _project_path), do: :ok

  defp maybe_cleanup(:wipe, project_path) do
    case ProjectRegistry.list_projects() |> Enum.find(&(&1.path == project_path)) do
      nil -> :ok
      project ->
        Logger.info("[EvalRunner] Cleaning up existing project #{project.id}")

        # Wipe volumes too so databases start fresh
        workspaces = ProjectRegistry.list_workspaces(project.id)
        Enum.each(workspaces, fn ws ->
          ws_id = BoomLooper.Workspace.workspace_id(ws.path)
          try do
            BoomLooper.Compose.down_volumes(ws.path, ws_id)
          rescue
            _ -> :ok
          catch
            _, _ -> :ok
          end
        end)

        ProjectRegistry.remove_project(project.id)
        Process.sleep(3_000)
    end
  end

  defp poll_agent(agent_id, deadline, interval, project_path, nudges, max_nudges) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      state = ChatAgent.get_state(agent_id)
      build_result(:timeout, state, project_path, nudges)
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
            # Agent went idle — check if services are healthy
            services = check_services(project_path)
            has_services = map_size(services) > 0
            all_healthy = Enum.all?(services, fn {_name, health} -> health == :healthy end)
            recent_errors = Enum.count(state.messages, fn m -> m[:role] == :error end)

            cond do
              has_services && all_healthy ->
                # Services are healthy - verify HTTP responds
                case verify_http_response(project_path) do
                  {:ok, status} ->
                    Logger.info("[EvalRunner] HTTP check passed: #{status}")
                    build_result(:completed, state, project_path, nudges)

                  {:error, reason} ->
                    Logger.warning("[EvalRunner] HTTP check failed: #{reason}")
                    if nudges >= max_nudges do
                      build_result(:http_failed, state, project_path, nudges)
                    else
                      Logger.info("[EvalRunner] Nudging to fix HTTP (#{nudges + 1}/#{max_nudges})")
                      ChatAgent.send_message(agent_id, "The service is running but HTTP requests fail: #{reason}. Please fix.")
                      Process.sleep(interval)
                      poll_agent(agent_id, deadline, interval, project_path, nudges + 1, max_nudges)
                    end
                end

              nudges >= max_nudges ->
                # Too many nudges — give up
                Logger.warning("[EvalRunner] Agent #{agent_id} idle after #{nudges} nudges, giving up")
                build_result(:stalled, state, project_path, nudges)

              recent_errors > 3 ->
                # Too many errors - something is broken
                Logger.warning("[EvalRunner] Agent #{agent_id} has #{recent_errors} errors, marking as failed")
                build_result(:failed, state, project_path, nudges)

              true ->
                # Still working — nudge the agent to continue
                Logger.info("[EvalRunner] Agent #{agent_id} idle, nudging (#{nudges + 1}/#{max_nudges})")
                ChatAgent.send_message(agent_id, "Continue setting up the development environment. Make sure all services are running and healthy.")
                Process.sleep(interval)
                poll_agent(agent_id, deadline, interval, project_path, nudges + 1, max_nudges)
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

  defp build_result(outcome, state, project_path, nudges) do
    services = check_services(project_path)
    messages = if state, do: state.messages, else: []

    error_messages =
      messages
      |> Enum.filter(fn m -> m[:role] == :error end)
      |> Enum.map(fn m -> m[:content] end)

    # Tool usage breakdown
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

    ## Services

    #{services_section}

    ## Tool Usage

    #{tools_section}

    ## Errors

    #{errors_section}

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
