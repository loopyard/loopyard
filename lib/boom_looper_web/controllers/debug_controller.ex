defmodule BoomLooperWeb.DebugController do
  use BoomLooperWeb, :controller

  @doc "GET /debug — dump system state as plain text"
  def index(conn, _params) do
    agents = BoomLooper.ChatAgent.list_agents()
    events = BoomLooper.EventLog.dump(100)

    agent_summary = agents
    |> Enum.map(fn a ->
      # Check if the GenServer process is alive (session PID is not in ETS summary)
      process_alive = case Registry.lookup(BoomLooper.ChatAgentRegistry, a.id) do
        [{pid, _}] -> Process.alive?(pid)
        [] -> false
      end

      "  #{a.name} (#{a.id}) status=#{a.status} errors=#{a.errors} tools=#{a.tool_calls} process=#{process_alive}"
    end)
    |> Enum.join("\n")

    containers = case System.cmd("docker", ["ps", "-a", "--filter", "name=boom-looper", "--format", "{{.Names}}\t{{.Status}}"], stderr_to_stdout: true) do
      {output, 0} -> output |> String.trim()
      _ -> "(docker not available)"
    end

    workspaces = BoomLooper.ProjectRegistry.list_projects()
    |> Enum.flat_map(fn p ->
      BoomLooper.ProjectRegistry.list_workspaces(p.id)
      |> Enum.map(fn w ->
        running = BoomLooper.WorkspaceSupervisor.workspace_running?(w.id)
        "  #{p.name}/#{w.name} (#{w.id}) status=#{w.status} supervisor=#{running}"
      end)
    end)
    |> Enum.join("\n")

    output = """
    === BOOM LOOPER DEBUG ===
    Time: #{DateTime.utc_now() |> Calendar.strftime("%Y-%m-%d %H:%M:%S UTC")}

    === WORKSPACES ===
    #{if workspaces == "", do: "  (none)", else: workspaces}

    === AGENTS (#{length(agents)}) ===
    #{if agent_summary == "", do: "  (none)", else: agent_summary}

    === CONTAINERS ===
    #{containers}

    === EVENT LOG (last 100) ===
    #{if events == "", do: "(no events)", else: events}
    """

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, output)
  end

  @doc "POST /reset — kill all workspaces, agents, and containers. Web layer stays up."
  def reset(conn, _params) do
    BoomLooper.EventLog.warning("system", "Reset triggered via /reset")

    # Explicitly tear down compose containers for all known projects
    # (ServiceManager.terminate no longer does this, so reset must)
    BoomLooper.ProjectRegistry.list_projects()
    |> Enum.flat_map(&BoomLooper.ProjectRegistry.list_workspaces(&1.id))
    |> Enum.each(fn w ->
      workspace_id = BoomLooper.Workspace.workspace_id(w.path)
      BoomLooper.Compose.down(w.path, workspace_id)
    end)

    # Kill all workspace supervisor trees (cascades to agents)
    children = DynamicSupervisor.which_children(BoomLooper.WorkspaceSupervisor)
    Enum.each(children, fn {_, pid, _, _} ->
      DynamicSupervisor.terminate_child(BoomLooper.WorkspaceSupervisor, pid)
    end)

    # Clear project/workspace registry
    BoomLooper.ProjectRegistry.list_projects()
    |> Enum.each(&BoomLooper.ProjectRegistry.remove_project(&1.id))

    # Clear agent ETS
    BoomLooper.ChatAgent.ensure_ets_table()
    :ets.delete_all_objects(:chat_agents)

    BoomLooper.EventLog.info("system", "Reset complete — all workspaces, agents, and containers stopped")

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, "Reset complete. All workspaces, agents, and containers stopped.\nGo to http://localhost:#{port()}/\n")
  end

  @doc "POST /reset/containers — kill only Docker containers, keep agents alive"
  def reset_containers(conn, _params) do
    BoomLooper.EventLog.warning("system", "Container reset triggered via /reset/containers")

    case System.cmd("docker", ["ps", "-q", "--filter", "name=boom-looper"], stderr_to_stdout: true) do
      {output, 0} ->
        ids = output |> String.trim() |> String.split("\n", trim: true)
        if ids != [] do
          System.cmd("docker", ["rm", "-f" | ids], stderr_to_stdout: true)
        end
      _ -> :ok
    end

    BoomLooper.EventLog.info("system", "All boom-looper containers killed")

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, "All boom-looper containers killed.\n")
  end

  defp port do
    Application.get_env(:boom_looper, BoomLooperWeb.Endpoint)[:http][:port] || 4000
  end
end
