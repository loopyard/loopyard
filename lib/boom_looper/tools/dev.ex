defmodule BoomLooper.Tools.Dev do
  @moduledoc """
  MCP tools for BoomLooper development/debugging.
  Only available when BOOMLOOPER_DEV_MCP=1.

  These give super-root access to BoomLooper internals - cleaning workspaces,
  stopping agents, resetting containers. Used for building BoomLooper with BoomLooper.
  """
  use ClaudeCode.MCP.Server, name: "boom-looper-dev"

  alias BoomLooper.{ChatAgent, Compose, ProjectRegistry, Workspace, EventLog}

  # --- Tool definitions ---

  tool :system_debug, "Get BoomLooper system state: workspaces, agents, containers, events" do
    def execute(_params) do
      agents = ChatAgent.list_agents()

      agent_summary = agents
      |> Enum.map(fn a ->
        process_alive = case Registry.lookup(BoomLooper.ChatAgentRegistry, a.id) do
          [{pid, _}] -> Process.alive?(pid)
          [] -> false
        end
        %{
          id: a.id,
          name: a.name,
          status: a.status,
          errors: a.errors,
          tool_calls: a.tool_calls,
          process_alive: process_alive,
          bind_mount: a[:bind_mount]
        }
      end)

      workspaces = ProjectRegistry.list_projects()
      |> Enum.flat_map(fn p ->
        ProjectRegistry.list_workspaces(p.id)
        |> Enum.map(fn w ->
          running = BoomLooper.WorkspaceSupervisor.workspace_running?(w.id)
          %{
            id: w.id,
            project: p.name,
            name: w.name,
            path: w.path,
            status: w.status,
            supervisor_running: running
          }
        end)
      end)

      containers = case System.cmd("docker", ["ps", "-a", "--filter", "name=bl-", "--format", "{{.Names}}\t{{.Status}}"], stderr_to_stdout: true) do
        {output, 0} ->
          output
          |> String.trim()
          |> String.split("\n", trim: true)
          |> Enum.map(fn line ->
            case String.split(line, "\t") do
              [name, status] -> %{name: name, status: status}
              _ -> nil
            end
          end)
          |> Enum.reject(&is_nil/1)
        _ -> []
      end

      events = EventLog.dump(20)

      {:ok, %{
        agents: agent_summary,
        workspaces: workspaces,
        containers: containers,
        recent_events: events
      }}
    end
  end

  tool :clean_workspace, "Clean a workspace: delete .boomlooper/workspace dir, stop agents and containers" do
    field :workspace_id, :string, required: true, description: "Workspace ID (e.g. '0a6a')"
    field :delete_config, :boolean, required: false, description: "Also delete workspace.json config (default: false)"

    def execute(%{workspace_id: workspace_id} = params) do
      delete_config = Map.get(params, :delete_config, false)
      workspace = ProjectRegistry.get_workspace(workspace_id)

      if workspace do
        workspace_dir = Path.join(workspace.path, ".boomlooper/workspace")
        config_path = Path.join(workspace.path, ".boomlooper/repo/workspace.json")

        # Stop any running agents for this workspace
        stopped_agents = ChatAgent.list_agents()
        |> Enum.filter(&(&1[:bind_mount] == workspace.path))
        |> Enum.map(fn a ->
          ChatAgent.stop_agent(a.id)
          a.id
        end)

        # Stop containers
        ws_id = Workspace.workspace_id(workspace.path)
        Compose.down(workspace.path, ws_id)

        # Delete workspace directory
        File.rm_rf(workspace_dir)

        # Optionally delete config
        if delete_config do
          File.rm(config_path)
        end

        EventLog.info("workspace:#{workspace_id}", "Workspace cleaned via dev MCP")

        {:ok, %{
          workspace_id: workspace_id,
          deleted_dir: workspace_dir,
          deleted_config: delete_config,
          stopped_agents: stopped_agents
        }}
      else
        {:error, "Workspace #{workspace_id} not found"}
      end
    end
  end

  tool :stop_agent, "Stop a running agent" do
    field :agent_id, :string, required: true, description: "Agent ID"

    def execute(%{agent_id: agent_id}) do
      case ChatAgent.stop_agent(agent_id) do
        :ok ->
          EventLog.info("agent:#{agent_id}", "Agent stopped via dev MCP")
          {:ok, %{agent_id: agent_id, stopped: true}}

        {:error, :not_found} ->
          {:error, "Agent #{agent_id} not found"}
      end
    end
  end

  tool :reset_containers, "Kill all BoomLooper Docker containers" do
    def execute(_params) do
      EventLog.warning("system", "Container reset triggered via dev MCP")

      killed = case System.cmd("docker", ["ps", "-q", "--filter", "name=bl-"], stderr_to_stdout: true) do
        {output, 0} ->
          ids = output |> String.trim() |> String.split("\n", trim: true)
          if ids != [] do
            System.cmd("docker", ["rm", "-f" | ids], stderr_to_stdout: true)
            ids
          else
            []
          end
        _ -> []
      end

      EventLog.info("system", "Killed #{length(killed)} containers via dev MCP")
      {:ok, %{killed_containers: killed}}
    end
  end

  tool :list_workspaces, "List all registered workspaces" do
    def execute(_params) do
      workspaces = ProjectRegistry.list_projects()
      |> Enum.flat_map(fn p ->
        ProjectRegistry.list_workspaces(p.id)
        |> Enum.map(fn w ->
          %{
            id: w.id,
            project_id: p.id,
            project_name: p.name,
            name: w.name,
            path: w.path,
            status: w.status,
            is_main: w.is_main
          }
        end)
      end)

      {:ok, %{workspaces: workspaces}}
    end
  end

  tool :list_agents, "List all running agents" do
    def execute(_params) do
      agents = ChatAgent.list_agents()
      |> Enum.map(fn a ->
        %{
          id: a.id,
          name: a.name,
          status: a.status,
          bind_mount: a[:bind_mount],
          errors: a.errors,
          tool_calls: a.tool_calls
        }
      end)

      {:ok, %{agents: agents}}
    end
  end
end
