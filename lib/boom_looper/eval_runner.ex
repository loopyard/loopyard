defmodule BoomLooper.EvalRunner do
  @moduledoc """
  Automates eval runs: launch a project, monitor the setup agent,
  record results. Handles max_turns by auto-nudging the agent when
  it goes idle before the checklist is complete.

  All evals run asynchronously under a Task.Supervisor. Use `status/0`
  to check progress and `results/0` to see completed runs.

  Usage:

    # Run by eval name (looks up git URL from priv/evals.json):
    mix boom.rpc 'BoomLooper.EvalRunner.eval("maybe-finance")'

    # Run by git URL:
    mix boom.rpc 'BoomLooper.EvalRunner.run("https://github.com/maybe-finance/maybe.git")'

    # Run by local path (legacy):
    mix boom.rpc 'BoomLooper.EvalRunner.run("/path/to/project")'

    # Check status:
    mix boom.rpc 'BoomLooper.EvalRunner.status()'

    # List available evals:
    mix boom.rpc 'BoomLooper.EvalRunner.list_evals()'
  """
  require Logger

  alias BoomLooper.ChatAgent
  alias BoomLooper.ProjectRegistry
  alias BoomLooper.Workspace

  @default_timeout 1_800_000  # 30 minutes
  @poll_interval 5_000       # 5 seconds
  @max_nudges 10             # allow several crash-fix-rebuild cycles

  @doc """
  List available evals from priv/evals.json.
  """
  def list_evals do
    load_eval_config()
    |> Enum.map(fn {name, config} -> %{name: name, git_url: config["git_url"]} end)
  end

  @doc """
  Run an eval by name (from priv/evals.json). Looks up the git URL and delegates to run/2.

      EvalRunner.eval("maybe-finance")
  """
  def eval(name, opts \\ []) do
    config = load_eval_config()
    case config[name] do
      nil -> {:error, "Unknown eval: #{name}. Available: #{config |> Map.keys() |> Enum.join(", ")}"}
      entry ->
        # Pass branch from config if present
        opts = if entry["branch"], do: Keyword.put(opts, :branch, entry["branch"]), else: opts
        run(entry["git_url"], opts)
    end
  end

  @doc """
  Run an eval asynchronously. Accepts a git URL or local path.
  Spawns a supervised task that outlives the RPC connection.

  Options:
    - :timeout — max wait time in ms (default: 30 minutes)
    - :poll_interval — how often to check agent state (default: 5s)
    - :max_nudges — max times to nudge an idle agent (default: 10)


  Returns {:ok, pid}.
  """
  def run(source, opts \\ []) do
    eval_name = source |> extract_name() |> sanitize_name()

    # Take over IExSession synchronously BEFORE the RPC returns — prevents flash when RPC disconnects
    # Claim prevents disconnect_unless_claimed from clearing it
    BoomLooper.IExSession.working("eval: #{eval_name} — starting")
    BoomLooper.IExSession.claim()

    {:ok, pid} = Task.Supervisor.start_child(BoomLooper.TaskSupervisor, fn ->
      BoomLooper.StateKeeper.put_eval(eval_name, %{pid: self(), source: source, started_at: DateTime.utc_now(), status: :running, result: nil})

      try do
        do_run(source, opts)
      rescue
        e ->
          Logger.error("[EvalRunner] Eval crashed for #{eval_name}: #{Exception.message(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}")
          BoomLooper.StateKeeper.put_eval(eval_name, %{pid: self(), source: source, started_at: DateTime.utc_now(), status: :crashed, result: %{outcome: :crashed, error: Exception.message(e)}})
      catch
        kind, reason ->
          Logger.error("[EvalRunner] Eval crashed for #{eval_name}: #{inspect({kind, reason})}")
          BoomLooper.StateKeeper.put_eval(eval_name, %{pid: self(), source: source, started_at: DateTime.utc_now(), status: :crashed, result: %{outcome: :crashed, error: inspect({kind, reason})}})
      after
        # Clear IExSession when eval is done (success, failure, or crash)
        BoomLooper.IExSession.disconnect()
      end
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

  # --- Core run logic ---

  defp do_run(source, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    poll_interval = Keyword.get(opts, :poll_interval, @poll_interval)
    max_nudges = Keyword.get(opts, :max_nudges, @max_nudges)
    is_git_url = git_url?(source)

    eval_name = source |> extract_name() |> sanitize_name()
    Logger.info("[EvalRunner] Starting eval for #{source}")
    started_at = System.monotonic_time(:millisecond)

    # Always start fresh — tear down any existing project
    BoomLooper.IExSession.working("eval: #{eval_name} — cleaning")
    clean_project(source, is_git_url)

    # Also delete any stale volume that might exist from manual testing
    # This ensures we start truly fresh even if clean_project didn't find a registered project
    if is_git_url do
      branch = Keyword.get(opts, :branch, "main")
      expected_ws_id = Workspace.workspace_id_from_git(source, branch)
      expected_volume = BoomLooper.VolumeManager.code_volume_name(expected_ws_id)
      BoomLooper.VolumeManager.delete_volume(expected_volume)

      # Also tear down any containers using this workspace_id
      virtual_dir = Path.join([Workspace.home_dir(), "workspaces", expected_ws_id])
      try do
        BoomLooper.Compose.down_volumes(virtual_dir, expected_ws_id)
      catch
        _, _ -> :ok
      end
    end

    # Add the project (git URL or local path)
    BoomLooper.IExSession.working("eval: #{eval_name} — adding project")
    case add_project(source, is_git_url, opts) do
      {:ok, project, workspace} ->
        # For volume-based workspaces, use the virtual dir as project_dir
        project_dir = if workspace[:volume_based] do
          Path.join([Workspace.home_dir(), "workspaces", workspace.id])
        else
          workspace.path
        end

        # Start workspace supervisor
        case BoomLooper.WorkspaceSupervisor.start_workspace(workspace.id, project_dir) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
        end

        # Kill existing eval agents, then spawn a new one
        for agent <- ChatAgent.list_agents(),
            (agent[:workspace_id] == workspace.id || agent[:working_dir] == project_dir),
            agent[:started_by] == "eval_runner" do
          ChatAgent.stop_agent(agent.id)
          ChatAgent.remove_agent(agent.id)
        end

        id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

        agent_opts = [
          id: id,
          name: "Setup",
          working_dir: project_dir,
          started_by: "eval_runner",
          workspace_id: workspace.id
        ]

        # Volume-based workspaces use volume mount, local use bind mount
        agent_opts = if workspace[:volume_based] do
          Keyword.put(agent_opts, :volume, workspace.volume)
        else
          Keyword.put(agent_opts, :bind_mount, workspace.path)
        end

        ChatAgent.register_booting(id, "Setup", project_dir)
        Task.start(fn -> BoomLooper.AgentBoot.boot(id, agent_opts) end)

        # Poll until done or timeout, with auto-nudging
        BoomLooper.IExSession.working("eval: #{project.name} — running")
        deadline = started_at + timeout
        result = poll_agent(id, deadline, poll_interval, project_dir, 0, max_nudges)

        # Record
        duration_ms = System.monotonic_time(:millisecond) - started_at
        result = Map.merge(result, %{
          source: source,
          project_name: project.name,
          project_path: project_dir,
          agent_id: id,
          duration_ms: duration_ms,
          timestamp: DateTime.utc_now()
        })

        record_run(project.name, result)
        Logger.info("[EvalRunner] Eval complete for #{project.name}: #{result.outcome}")

        # Update ETS tracking
        eval_name = source |> extract_name() |> sanitize_name()
        case BoomLooper.StateKeeper.get_eval(eval_name) do
          nil -> :ok
          info -> BoomLooper.StateKeeper.put_eval(eval_name, %{info | status: :done, result: result})
        end

        {:ok, result}

      {:error, reason} ->
        {:error, "Failed to add project: #{reason}"}
    end
  end

  # --- Project management helpers ---

  defp git_url?(source) do
    String.starts_with?(source, "https://") or
    String.starts_with?(source, "http://") or
    String.starts_with?(source, "git@")
  end

  defp add_project(source, true = _is_git_url, opts) do
    branch = Keyword.get(opts, :branch, "main")
    ProjectRegistry.add_from_url(source, branch: branch)
  end

  defp add_project(source, false = _is_git_url, _opts) do
    ProjectRegistry.add(Path.expand(source))
  end

  defp clean_project(source, is_git_url) do
    project = if is_git_url do
      ProjectRegistry.list_projects()
      |> Enum.find(&(&1[:git_url] == source))
    else
      path = Path.expand(source)
      ProjectRegistry.list_projects()
      |> Enum.find(&(&1[:path] == path))
    end

    case project do
      nil -> :ok
      project ->
        Logger.info("[EvalRunner] Cleaning up existing project #{project.id}")

        # Kill all agents for this project
        for agent <- ChatAgent.list_agents(),
            agent[:working_dir] == project[:path] ||
            agent[:workspace_id] in workspace_ids_for(project.id) do
          ChatAgent.stop_agent(agent.id)
          ChatAgent.remove_agent(agent.id)
        end

        # Stop workspace supervisors, tear down containers, wipe volumes
        workspaces = ProjectRegistry.list_workspaces(project.id)
        Enum.each(workspaces, fn ws ->
          ws_id = ws.id

          BoomLooper.WorkspaceSupervisor.stop_workspace(ws_id)

          virtual_dir = Path.join([Workspace.home_dir(), "workspaces", ws_id])
          try do
            BoomLooper.Compose.down_volumes(virtual_dir, ws_id)
          rescue
            _ -> :ok
          catch
            _, _ -> :ok
          end

          # Delete external code volume
          BoomLooper.VolumeManager.delete_volume(BoomLooper.VolumeManager.code_volume_name(ws_id))

          # Delete agents.log so stale agents aren't replayed
          agents_log = Path.join([virtual_dir, ".boomlooper", "workspace", "agents.log"])
          File.rm(agents_log)
        end)

        ProjectRegistry.remove_project(project.id)
        Process.sleep(3_000)
    end
  end

  defp workspace_ids_for(project_id) do
    ProjectRegistry.list_workspaces(project_id)
    |> Enum.map(& &1.id)
  end

  defp extract_name(source) do
    if git_url?(source) do
      source
      |> String.replace(~r/\.git$/, "")
      |> String.split("/")
      |> List.last()
      |> String.split(":")
      |> List.last()
    else
      Path.basename(Path.expand(source))
    end
  end

  # --- Service checking ---

  @doc """
  Check if a workspace's services are healthy.
  Returns a map of service name => status.
  """
  def check_services(workspace_key) do
    # Use ServiceStatus for consistent service enumeration
    workspace_key
    |> BoomLooper.Workspace.ServiceStatus.for_workspace()
    |> Map.new(fn s -> {s.name, s.status} end)
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  @doc """
  Try to fetch an HTTP response from any dev service with a mapped port.
  Returns {:ok, status_code, body_preview} or :no_response.
  """
  def probe_web_service(workspace_key) do
    # Use ServiceStatus for consistent service enumeration
    # It reads from docker-compose.yml and merges running state from Docker
    workspace_key
    |> BoomLooper.Workspace.ServiceStatus.for_workspace()
    |> Enum.filter(fn s -> s.type == :process && s.status == :running && s[:ports] != nil && s[:ports] != %{} end)
    |> Enum.find_value(:no_response, fn service ->
      service.ports
      |> Enum.find_value(:no_response, fn {_container_port, host_port} ->
        case http_get("http://localhost:#{host_port}") do
          {:ok, status, body} -> {:ok, status, body}
          :error -> nil
        end
      end)
    end)
  rescue
    _ -> :no_response
  catch
    _, _ -> :no_response
  end

  defp http_get(url) do
    :inets.start()
    :ssl.start()

    case :httpc.request(:get, {String.to_charlist(url), []}, [timeout: 5_000, connect_timeout: 3_000], body_format: :binary) do
      {:ok, {{_, status, _}, _headers, body}} ->
        {:ok, status, String.slice(to_string(body), 0..500)}

      _ ->
        :error
    end
  end

  # --- Polling ---

  defp poll_agent(agent_id, deadline, interval, workspace_key, nudges, max_nudges) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      state = ChatAgent.get_state(agent_id)
      case probe_web_service(workspace_key) do
        {:ok, status, body} when status in 200..399 ->
          # Accept 2xx success, 3xx redirects as "working"
          Logger.info("[EvalRunner] Timed out but web service is healthy (HTTP #{status})")
          build_result(:success, state, workspace_key, nudges, %{http_status: status, http_body_preview: body})
        {:ok, status, body} ->
          build_result(:web_error, state, workspace_key, nudges, %{http_status: status, http_body_preview: body})
        :no_response ->
          build_result(:timeout, state, workspace_key, nudges)
      end
    else
      case ChatAgent.get_state(agent_id) do
        nil ->
          Process.sleep(interval)
          poll_agent(agent_id, deadline, interval, workspace_key, nudges, max_nudges)

        %{status: status} when status in [:booting, :thinking] ->
          Process.sleep(interval)
          poll_agent(agent_id, deadline, interval, workspace_key, nudges, max_nudges)

        %{status: :idle} = state ->
          if length(state.messages) < 2 do
            Process.sleep(interval)
            poll_agent(agent_id, deadline, interval, workspace_key, nudges, max_nudges)
          else
            case probe_web_service(workspace_key) do
                {:ok, status, body} when status in 200..399 ->
                  # Accept 2xx success, 3xx redirects as "working"
                  Logger.info("[EvalRunner] Web service healthy (HTTP #{status}), declaring success")
                  build_result(:success, state, workspace_key, nudges, %{
                    http_status: status,
                    http_body_preview: body
                  })

                {:ok, status, body} ->
                  Logger.info("[EvalRunner] Web service error (HTTP #{status}), nudging with error body")
                  if nudges >= max_nudges do
                    build_result(:web_error, state, workspace_key, nudges, %{
                      http_status: status,
                      http_body_preview: body
                    })
                  else
                    nudge_msg = "The web service is returning HTTP #{status}. Here's the response body — fix the issue:\n\n```\n#{body}\n```"
                    ChatAgent.send_message(agent_id, nudge_msg)
                    Process.sleep(interval)
                    poll_agent(agent_id, deadline, interval, workspace_key, nudges + 1, max_nudges)
                  end

                :no_response ->
                  if nudges >= max_nudges do
                    Logger.warning("[EvalRunner] Agent #{agent_id} idle after #{nudges} nudges, giving up")
                    build_result(:stalled, state, workspace_key, nudges)
                  else
                    Logger.info("[EvalRunner] Agent #{agent_id} idle, no web response, nudging (#{nudges + 1}/#{max_nudges})")
                    services = check_services(workspace_key)
                    svc_summary = services |> Enum.map(fn {n, s} -> "#{n}: #{s}" end) |> Enum.join(", ")
                    nudge_msg = "The dev server is not responding to HTTP requests. Services: #{svc_summary}. " <>
                      "Run `service_status` to check container state, then `logs` on the dev container to see the crash output. " <>
                      "Fix the issue, `rebuild`, and check again. You are NOT done until the dev server returns HTTP 200."
                    ChatAgent.send_message(agent_id, nudge_msg)
                    Process.sleep(interval)
                    poll_agent(agent_id, deadline, interval, workspace_key, nudges + 1, max_nudges)
                  end
            end
          end

        %{status: status} = state when status in [:stopped, :crashed] ->
          build_result(:failed, state, workspace_key, nudges)

        _other ->
          Process.sleep(interval)
          poll_agent(agent_id, deadline, interval, workspace_key, nudges, max_nudges)
      end
    end
  end

  defp build_result(outcome, state, workspace_key, nudges, extra \\ %{}) do
    services = check_services(workspace_key)
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

  # --- Recording ---

  @doc """
  Record an eval run. If project is in `evals/<name>/project/`, writes to
  sibling `runs/` directory. Otherwise writes to `evals/<project_name>/runs/`.
  """
  def record_run(project_name, result) do
    dir = runs_dir(result.source, project_name)
    File.mkdir_p!(dir)

    date = Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d_%H%M%S")
    path = Path.join(dir, "#{date}.md")

    content = format_result(result)
    File.write!(path, content)

    Logger.info("[EvalRunner] Recorded eval to #{path}")
    path
  end

  defp runs_dir(project_path, project_name) do
    # Check if project is in evals/<name>/project/ pattern
    if Path.basename(project_path) == "project" do
      parent = Path.dirname(project_path)
      grandparent = Path.dirname(parent)
      if Path.basename(grandparent) == "evals" do
        # Write to sibling runs/ directory
        Path.join(parent, "runs")
      else
        Path.join(["evals", sanitize_name(project_name), "runs"])
      end
    else
      Path.join(["evals", sanitize_name(project_name), "runs"])
    end
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
    ## Source

    #{result.source}
    """
  end

  # --- Config ---

  defp load_eval_config do
    Path.wildcard("evals/*/eval.md")
    |> Map.new(fn path ->
      name = path |> Path.dirname() |> Path.basename()
      frontmatter = parse_frontmatter(File.read!(path))
      {name, frontmatter}
    end)
  end

  defp parse_frontmatter(content) do
    case Regex.run(~r/\A---\n(.*?)\n---/s, content) do
      [_, yaml] ->
        yaml
        |> String.split("\n")
        |> Map.new(fn line ->
          case String.split(line, ":", parts: 2) do
            [k, v] -> {String.trim(k), String.trim(v)}
            _ -> {"", ""}
          end
        end)
        |> Map.delete("")

      nil ->
        %{}
    end
  end

  defp sanitize_name(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]/, "_")
    |> String.trim("_")
  end
end
