defmodule BoomLooper.EvalRunner do
  @moduledoc """
  Automates eval runs: launch a project, monitor the setup agent,
  record results. Handles max_turns by auto-nudging the agent when
  it goes idle before the checklist is complete.

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
    - :clean — remove existing project first (default: false)

  Returns {:ok, result} or {:error, reason}.
  """
  def run(project_path, opts \\ []) do
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
          ProjectRegistry.remove_project(project.id)
          # Give docker compose down a moment
          Process.sleep(5_000)
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
        setup = BoomLooper.Checklist.available(workspace.path) |> Enum.find(&(&1.id == "setup"))
        name = if setup, do: setup.name, else: "Setup"
        checklist_id = if setup, do: "setup"

        agent_opts = [
          id: id,
          name: name,
          working_dir: workspace.path,
          started_by: "eval_runner",
          bind_mount: workspace.path
        ]

        ChatAgent.register_booting(id, name, workspace.path)
        Task.start(fn -> BoomLooper.AgentBoot.boot(id, agent_opts, checklist_id: checklist_id) end)

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
        Logger.info("[EvalRunner] Eval complete for #{project.name}: #{result.outcome} (#{result.checklist_checked}/#{result.checklist_total})")

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

  # --- Private ---

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
            # Agent went idle — check checklist progress
            {checked, total} = checklist_progress(agent_id, project_path)

            cond do
              checked == total && total > 0 ->
                # Checklist complete
                build_result(:completed, state, project_path, nudges)

              nudges >= max_nudges ->
                # Too many nudges — give up
                Logger.warning("[EvalRunner] Agent #{agent_id} idle at #{checked}/#{total} after #{nudges} nudges, giving up")
                build_result(:stalled, state, project_path, nudges)

              true ->
                # Checklist incomplete — nudge the agent to continue
                Logger.info("[EvalRunner] Agent #{agent_id} idle at #{checked}/#{total}, nudging (#{nudges + 1}/#{max_nudges})")
                ChatAgent.send_message(agent_id, "Continue with the remaining checklist items.")
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

  defp checklist_progress(agent_id, project_path) do
    # Try to find the active checklist file
    active_dir = Path.join(project_path, ".boomlooper/workspace/active")

    case File.ls(active_dir) do
      {:ok, files} ->
        case Enum.find(files, &String.starts_with?(&1, "#{agent_id}-")) do
          nil -> {0, 0}
          file ->
            path = Path.join(active_dir, file)
            case BoomLooper.Checklist.progress_from_file(path) do
              {:ok, {checked, total}} -> {checked, total}
              _ -> {0, 0}
            end
        end

      _ ->
        {0, 0}
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

    {checked, total} =
      if state do
        checklist_progress(state[:id] || "", project_path)
      else
        {0, 0}
      end

    %{
      outcome: outcome,
      status: state && state[:status],
      message_count: length(messages),
      tool_calls: (state && state[:tool_calls]) || 0,
      errors: length(error_messages),
      error_messages: error_messages,
      services: services,
      nudges: nudges,
      checklist_checked: checked,
      checklist_total: total,
      tool_usage: tool_usage
    }
  end

  @doc """
  Record an eval run to `evals/:project_name/:date.md`.
  """
  def record_run(project_name, result) do
    dir = Path.join(["evals", sanitize_name(project_name)])
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
    - **Checklist:** #{result.checklist_checked}/#{result.checklist_total}

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
