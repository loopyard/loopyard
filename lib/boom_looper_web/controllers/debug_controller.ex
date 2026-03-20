defmodule BoomLooperWeb.DebugController do
  use BoomLooperWeb, :controller

  def index(conn, _params) do
    agents = BoomLooper.ChatAgent.list_agents()
    events = BoomLooper.EventLog.dump(100)

    agent_summary = agents
    |> Enum.map(fn a ->
      session_alive = try do
        BoomLooper.Agent.Backend.ClaudeCode.session_alive?(a[:session])
      rescue
        _ -> "unknown"
      catch
        _ -> "unknown"
      end

      "  #{a.name} (#{a.id}) status=#{a.status} errors=#{a.errors} tools=#{a.tool_calls} session=#{session_alive}"
    end)
    |> Enum.join("\n")

    # Container states
    containers = case System.cmd("docker", ["ps", "-a", "--filter", "name=boom-looper", "--format", "{{.Names}}\t{{.Status}}"], stderr_to_stdout: true) do
      {output, 0} -> output |> String.trim()
      _ -> "(docker not available)"
    end

    output = """
    === BOOM LOOPER DEBUG ===
    Time: #{DateTime.utc_now() |> Calendar.strftime("%Y-%m-%d %H:%M:%S UTC")}

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
end
