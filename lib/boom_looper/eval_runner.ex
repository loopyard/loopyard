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

  # Heavy Rails apps (chatwoot, discourse) need more than 30 minutes
  # for clone + image build + bundle install + asset precompile. The
  # discourse round-1 eval was still actively iterating at the 30-min
  # mark and hit :timeout with the dev container healthy. 45 gives
  # enough headroom for big Ruby/Node apps; small projects still
  # finish in 5-10 min so there's no cost.
  @default_timeout 2_700_000  # 45 minutes
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
    project_path = eval_project_path(eval_name)
    clean_eval_project(project_path)

    # For git URLs: clone into evals/<name>/project/ using the host's git
    # binary (picks up SSH keys, credential helpers, etc). The cloned dir
    # is then registered as a Local project — no special GitHub adapter.
    if is_git_url do
      branch = Keyword.get(opts, :branch, "main")
      BoomLooper.IExSession.working("eval: #{eval_name} — cloning")
      File.rm_rf!(project_path)
      File.mkdir_p!(Path.dirname(project_path))

      case host_git_clone(source, branch, project_path) do
        {:ok, _} -> :ok
        {:error, reason} ->
          record_eval_failure(eval_name, source, started_at, "Clone failed: #{reason}")
          raise "Clone failed: #{reason}"
      end
    end

    # Add the project via the Local path (works for both git-cloned and
    # local-path evals — the Local adapter just needs a directory with code)
    BoomLooper.IExSession.working("eval: #{eval_name} — adding project")
    effective_source = if is_git_url, do: project_path, else: Path.expand(source)
    case ProjectRegistry.add(effective_source) do
      {:ok, project, workspace} ->
        project_dir = workspace.path

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

        volume_name = BoomLooper.Workspace.volume_name_for(workspace.id)

        agent_opts = [
          id: id,
          name: "Setup",
          working_dir: project_dir,
          started_by: "eval_runner",
          workspace_id: workspace.id,
          volume: volume_name
        ]

        ChatAgent.register_booting(id, "Setup", project_dir)
        Task.Supervisor.start_child(BoomLooper.TaskSupervisor, fn -> BoomLooper.AgentBoot.boot(id, agent_opts) end)

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
        # Add-project failed (usually: git clone returned non-zero). We
        # MUST record this as a proper failed eval — don't silently
        # return {:error, ...}. Otherwise the StateKeeper shows
        # status: :done / result: nil and the run file is never written,
        # which looks identical to "eval never started".
        duration_ms = System.monotonic_time(:millisecond) - started_at
        project_name = eval_name

        # Keys here must match what format_result/record_run expect,
        # OR record_run will crash with KeyError and the whole eval
        # task gets marked :crashed. Learned that the hard way mid-round.
        result = %{
          outcome: :failed,
          source: source,
          project_name: project_name,
          project_path: nil,
          agent_id: nil,
          duration_ms: duration_ms,
          timestamp: DateTime.utc_now(),
          nudges: 0,
          error: reason,
          services: [],
          errors: 1,
          error_messages: [reason],
          last_messages: [],
          message_count: 0,
          tool_calls: 0,
          tool_usage: %{}
        }

        record_run(project_name, result)
        Logger.error("[EvalRunner] Eval failed for #{project_name}: #{reason}")

        case BoomLooper.StateKeeper.get_eval(eval_name) do
          nil -> :ok
          info -> BoomLooper.StateKeeper.put_eval(eval_name, %{info | status: :done, result: result})
        end

        {:error, "Failed to add project: #{reason}"}
    end
  end

  # --- Project management helpers ---

  defp git_url?(source) do
    String.starts_with?(source, "https://") or
    String.starts_with?(source, "http://") or
    String.starts_with?(source, "git@")
  end

  # Path where eval project clones live: evals/<name>/project/
  defp eval_project_path(eval_name) do
    Path.join([File.cwd!(), "evals", eval_name, "project"])
  end

  @clone_timeout 300_000

  # Clone a git repo using the host's git binary (picks up SSH keys,
  # credential helpers, .gitconfig). This is eval-specific infrastructure —
  # Local projects assume the user already cloned.
  defp host_git_clone(git_url, branch, dest) do
    git_path = System.find_executable("git")

    unless git_path do
      {:error, "git not found on host PATH"}
    else
      port = Port.open(
        {:spawn_executable, git_path},
        [:binary, :exit_status, :stderr_to_stdout,
         {:args, ["clone", "--branch", branch, "--depth", "1", git_url, dest]}]
      )

      collect_port_output(port, "", @clone_timeout)
    end
  end

  defp collect_port_output(port, acc, timeout) do
    receive do
      {^port, {:data, data}} ->
        collect_port_output(port, acc <> data, timeout)

      {^port, {:exit_status, 0}} ->
        {:ok, acc}

      {^port, {:exit_status, _code}} ->
        {:error, acc}
    after
      timeout ->
        Port.close(port)
        {:error, acc <> "\n(timed out)"}
    end
  end

  defp record_eval_failure(eval_name, source, started_at, error) do
    duration_ms = System.monotonic_time(:millisecond) - started_at
    result = %{outcome: :failed, error: error, source: source, project_name: eval_name, duration_ms: duration_ms}
    BoomLooper.StateKeeper.put_eval(eval_name, %{pid: self(), source: source, started_at: DateTime.utc_now(), status: :done, result: result})
  end

  defp clean_eval_project(project_path) do
    # Find the registered project by path
    expanded = Path.expand(project_path)
    project = ProjectRegistry.list_projects()
      |> Enum.find(&(&1[:path] == expanded))

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

        # Prune leaked temp containers (alpine, alpine/git) from
        # timed-out VolumeManager operations during the teardown above.
        BoomLooper.Docker.prune_temp_containers()

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
  Try to fetch an HTTP response from this workspace's dev-serving
  container. Returns {:ok, status_code, body_preview} or :no_response.

  ## What we probe, in priority order

  1. The **workspace** container (`bl-<ws_id>-workspace-1`). Many
     agents run the dev server directly inside workspace — common on
     pnpm monorepos, Go single-binaries, and anything where a second
     container is awkward. If workspace has a published port and it
     answers HTTP, that's the dev server.
  2. The **dev** container (`bl-<ws_id>-dev-1`). This is what the
     prompt template recommends; agents that follow the template use
     it and it's a clean home for the dev server.
  3. Any other container in the workspace (last-resort fallback).

  We skip admin UIs like inbucket/minio because probing them first
  would produce a false success: inbucket returning HTTP 200 on its
  mail-admin page has nothing to do with whether the actual dev app
  is up. Workspace-first and dev-first make the probe model what a
  user cares about (the port link in the UI).

  The earlier version filtered to compose `:process` services only
  AND used `[:ports]` Access syntax on a Service struct — the Access
  call raised, the rescue below silently converted every probe to
  `:no_response`, and we chased phantom "stalls" through a whole eval
  round before catching it.
  """
  def probe_web_service(workspace_key) do
    workspace_id = BoomLooper.Workspace.workspace_id(workspace_key)
    project_name = BoomLooper.Compose.project_name(workspace_id)

    containers =
      BoomLooper.Docker.list_containers(prefix: "#{project_name}-")
      |> Enum.filter(& &1.running)

    workspace_name = "#{project_name}-workspace-1"
    dev_name = "#{project_name}-dev-1"

    priority_names = [workspace_name, dev_name]

    priority = Enum.filter(containers, fn c -> c.name in priority_names end)
    fallback = Enum.reject(containers, fn c -> c.name in priority_names end)

    ports =
      (priority ++ fallback)
      |> Enum.flat_map(&container_host_ports/1)
      |> Enum.uniq()

    # Try each port; if ALL come back with no connection, wait briefly
    # and try once more. Absorbs the "agent declared done, dev server
    # still binding" race — common with Rails/Node startup. A single
    # 2s pause catches ~all of these without adding much total wait.
    case try_ports(ports) do
      :no_response ->
        Process.sleep(2_000)
        try_ports(ports)

      result ->
        result
    end
  rescue
    _ -> :no_response
  catch
    _, _ -> :no_response
  end

  defp try_ports(ports) do
    Enum.find_value(ports, :no_response, fn host_port ->
      case http_get("http://localhost:#{host_port}") do
        {:ok, status, body} -> {:ok, status, body}
        :error -> nil
      end
    end)
  end

  defp container_host_ports(%{name: name}) do
    name
    |> BoomLooper.Docker.container_ports()
    |> Map.values()
    |> Enum.map(&to_string/1)
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
          cond do
            length(state.messages) < 2 ->
              Process.sleep(interval)
              poll_agent(agent_id, deadline, interval, workspace_key, nudges, max_nudges)

            # If the MOST RECENT message is a "session died, retry"
            # error, that's Claude Code SDK instability — not the
            # agent running out of ideas. Send a plain "Continue."
            # to restart the session WITHOUT counting it as a nudge.
            # The nudge counter is a teaching signal, not a retry
            # counter — conflating them makes "zero nudges" unreachable
            # on long evals because any SDK hiccup bumps the count.
            session_died?(state) ->
              Logger.info("[EvalRunner] Session crash detected, retrying (not counted as nudge)")
              ChatAgent.send_message(agent_id, "Continue.")
              Process.sleep(interval)
              poll_agent(agent_id, deadline, interval, workspace_key, nudges, max_nudges)

            true ->
              handle_idle_probe(agent_id, state, deadline, interval, workspace_key, nudges, max_nudges)
          end

        %{status: status} = state when status in [:stopped, :crashed] ->
          build_result(:failed, state, workspace_key, nudges)

        _other ->
          Process.sleep(interval)
          poll_agent(agent_id, deadline, interval, workspace_key, nudges, max_nudges)
      end
    end
  end

  # The SDK's "session died" error surfaces as a message with role :error
  # and content that contains "Agent stopped responding". When THIS is the
  # most recent message, the agent went idle because the CLI crashed, not
  # because it ran out of ideas.
  defp session_died?(%{messages: messages}) do
    case List.last(messages) do
      %{role: :error, content: content} when is_binary(content) ->
        String.contains?(content, "Agent stopped responding")

      _ ->
        false
    end
  end

  defp handle_idle_probe(agent_id, state, deadline, interval, workspace_key, nudges, max_nudges) do
    case probe_web_service(workspace_key) do
      {:ok, status, body} when status in 200..399 ->
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
          nudge_msg = build_stall_nudge(workspace_key, nudges + 1, max_nudges)
          ChatAgent.send_message(agent_id, nudge_msg)
          Process.sleep(interval)
          poll_agent(agent_id, deadline, interval, workspace_key, nudges + 1, max_nudges)
        end
    end
  end

  # Nudge text that tells the agent WHAT the runner is probing and WHY
  # its own `curl dev:3000` from inside the workspace container might
  # disagree. Agents repeatedly got stuck because they kept verifying
  # from container-internal (which works) while the runner probes
  # `http://localhost:<host_port>` from the host (which fails when the
  # app binds to 127.0.0.1 inside the container).
  #
  # Escalates with nudge count so the agent knows it's looping.
  defp build_stall_nudge(workspace_key, nudge_num, max_nudges) do
    services = check_services(workspace_key)
    svc_summary = services |> Enum.map(fn {n, s} -> "#{n}: #{s}" end) |> Enum.join(", ")
    candidate_ports = discover_candidate_ports(workspace_key)

    probe_target_hint =
      case candidate_ports do
        [] ->
          "I can't find ANY published host ports on workspace or dev containers. " <>
            "Your docker-compose.yml needs an explicit `ports:` mapping on the dev service " <>
            "(e.g. `ports: [\"3000\"]`) — without it the runner can't reach your app from the host."

        ports ->
          "I tried these published host ports: #{Enum.join(ports, ", ")} — all connection-refused or timed out."
      end

    escalation =
      cond do
        nudge_num == 1 ->
          "This is your FIRST nudge. The probe is HOST-SIDE, not container-side. " <>
            "If `curl dev:3000` from inside the workspace container returns 200 but this probe fails, " <>
            "your dev server is bound to 127.0.0.1 (container-internal only) and needs to bind to 0.0.0.0. " <>
            "Rails: `-b 0.0.0.0` or `BINDING=0.0.0.0`. Next.js: `--hostname 0.0.0.0`. Flask/Django: `0.0.0.0:PORT`."

        nudge_num >= 3 ->
          "This is nudge #{nudge_num}/#{max_nudges}. You've been looping. STOP re-running the same diagnosis. " <>
            "The runner probes `http://localhost:<published_host_port>` from the HOST (not from any container). " <>
            "Do NOT rewrite docker-compose.yml or the Dockerfile — rebuilds change host ports and make things worse. " <>
            "Make ONE targeted change based on `logs`."

        true ->
          "Nudge #{nudge_num}/#{max_nudges}."
      end

    """
    The eval runner's HTTP probe failed. Services: #{svc_summary}.

    #{probe_target_hint}

    #{escalation}

    Do NOT delete or rename the `dev` service. Do NOT rewrite the whole \
    docker-compose.yml.
    """
  end

  defp discover_candidate_ports(workspace_key) do
    workspace_id = BoomLooper.Workspace.workspace_id(workspace_key)
    project_name = BoomLooper.Compose.project_name(workspace_id)

    for c <- BoomLooper.Docker.list_containers(prefix: "#{project_name}-"),
        c.running,
        c.name in ["#{project_name}-workspace-1", "#{project_name}-dev-1"],
        port <- container_host_ports(c) do
      port
    end
    |> Enum.uniq()
  rescue
    _ -> []
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
