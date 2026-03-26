defmodule BoomLooper.EvalRunner do
  @moduledoc """
  Automates eval runs: launch a project, monitor the setup agent,
  record results. Used to verify that setup works end-to-end.

  Usage:
    BoomLooper.EvalRunner.run("/path/to/project")
    BoomLooper.EvalRunner.run("/path/to/project", timeout: 600_000)
  """
  require Logger

  alias BoomLooper.ChatAgent
  alias BoomLooper.ProjectRegistry

  @default_timeout 600_000  # 10 minutes
  @poll_interval 5_000      # 5 seconds

  @doc """
  Run an eval: add the project, spawn a setup agent, wait for completion,
  and record the result. Blocks until done or timeout.

  Options:
    - :timeout — max wait time in ms (default: 10 minutes)
    - :poll_interval — how often to check agent state (default: 5s)

  Returns {:ok, result} or {:error, reason}.
  """
  def run(project_path, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    poll_interval = Keyword.get(opts, :poll_interval, @poll_interval)
    project_path = Path.expand(project_path)

    Logger.info("[EvalRunner] Starting eval for #{project_path}")
    started_at = System.monotonic_time(:millisecond)

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

        # Step 4: Poll until done or timeout
        deadline = started_at + timeout
        result = poll_agent(id, deadline, poll_interval, project_path)

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

  defp poll_agent(agent_id, deadline, interval, project_path) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      state = ChatAgent.get_state(agent_id)
      build_result(:timeout, state, project_path)
    else
      case ChatAgent.get_state(agent_id) do
        nil ->
          # Agent not started yet — wait
          Process.sleep(interval)
          poll_agent(agent_id, deadline, interval, project_path)

        %{status: :booting} ->
          Process.sleep(interval)
          poll_agent(agent_id, deadline, interval, project_path)

        %{status: :thinking} ->
          Process.sleep(interval)
          poll_agent(agent_id, deadline, interval, project_path)

        %{status: :idle} = state ->
          # Idle could mean: just started (no messages yet), or done
          if length(state.messages) < 2 do
            # Just started, wait for work to begin
            Process.sleep(interval)
            poll_agent(agent_id, deadline, interval, project_path)
          else
            # Agent went idle after doing work — check if it looks successful
            build_result(:completed, state, project_path)
          end

        %{status: status} = state when status in [:stopped, :crashed] ->
          build_result(:failed, state, project_path)

        _other ->
          Process.sleep(interval)
          poll_agent(agent_id, deadline, interval, project_path)
      end
    end
  end

  defp build_result(outcome, state, project_path) do
    services = check_services(project_path)
    messages = if state, do: state.messages, else: []

    error_messages =
      messages
      |> Enum.filter(fn m -> m[:role] == :error end)
      |> Enum.map(fn m -> m[:content] end)

    %{
      outcome: outcome,
      status: state && state[:status],
      message_count: length(messages),
      tool_calls: (state && state[:tool_calls]) || 0,
      errors: length(error_messages),
      error_messages: error_messages,
      services: services
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
        errors -> Enum.map_join(errors, "\n", fn e -> "- #{String.slice(e, 0..200)}" end)
      end

    """
    # Eval: #{result.project_name}

    - **Date:** #{result.timestamp}
    - **Outcome:** #{result.outcome}
    - **Agent ID:** #{result.agent_id}
    - **Duration:** #{div(result.duration_ms, 1000)}s
    - **Messages:** #{result.message_count}
    - **Tool calls:** #{result.tool_calls}
    - **Errors:** #{result.errors}

    ## Services

    #{services_section}

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
