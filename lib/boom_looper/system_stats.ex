defmodule BoomLooper.SystemStats do
  @moduledoc """
  Collects resource usage stats at three levels:
  1. Host system — total RAM, CPU, disk
  2. This app — BEAM VM memory, process counts
  3. Per agent — Docker container, Claude CLI process, GenServer
  """

  alias BoomLooper.ChatAgent

  # --- Host System ---

  @doc "Host machine stats: CPU, RAM, disk"
  def host_stats do
    %{
      cpu: host_cpu(),
      memory: host_memory(),
      disk: host_disk(),
      uptime: host_uptime()
    }
  end

  defp host_cpu do
    # macOS: use sysctl for core count, top for load
    cores =
      case System.cmd("sysctl", ["-n", "hw.ncpu"], stderr_to_stdout: true) do
        {output, 0} -> String.trim(output) |> String.to_integer()
        _ -> :erlang.system_info(:schedulers_online)
      end

    load =
      case System.cmd("sysctl", ["-n", "vm.loadavg"], stderr_to_stdout: true) do
        {output, 0} ->
          # Format: "{ 1.23 2.34 3.45 }"
          output
          |> String.trim()
          |> String.replace(~r/[{}]/, "")
          |> String.trim()
          |> String.split(~r/\s+/)
          |> Enum.take(3)
          |> Enum.map(fn s ->
            case Float.parse(s) do
              {f, _} -> f
              :error -> 0.0
            end
          end)

        _ ->
          [0.0, 0.0, 0.0]
      end

    %{cores: cores, load_avg: load}
  end

  defp host_memory do
    # macOS: vm_stat for memory breakdown
    case System.cmd("vm_stat", [], stderr_to_stdout: true) do
      {output, 0} ->
        page_size = 16384  # macOS default on Apple Silicon (16KB)

        pages =
          Regex.scan(~r/^(.+?):\s+(\d+)/m, output)
          |> Map.new(fn [_, key, val] -> {String.trim(key), String.to_integer(val)} end)

        free = Map.get(pages, "Pages free", 0) * page_size
        active = Map.get(pages, "Pages active", 0) * page_size
        inactive = Map.get(pages, "Pages inactive", 0) * page_size
        wired = Map.get(pages, "Pages wired down", 0) * page_size
        compressed = Map.get(pages, "Pages occupied by compressor", 0) * page_size

        total =
          case System.cmd("sysctl", ["-n", "hw.memsize"], stderr_to_stdout: true) do
            {out, 0} -> String.trim(out) |> String.to_integer()
            _ -> free + active + inactive + wired + compressed
          end

        used = active + wired + compressed

        %{total: total, used: used, free: free, inactive: inactive, compressed: compressed}

      _ ->
        %{total: 0, used: 0, free: 0, inactive: 0, compressed: 0}
    end
  end

  defp host_disk do
    case System.cmd("df", ["-h", "/"], stderr_to_stdout: true) do
      {output, 0} ->
        lines = String.split(output, "\n", trim: true)

        case Enum.at(lines, 1) do
          nil ->
            %{total: "?", used: "?", available: "?", use_pct: "?"}

          line ->
            parts = String.split(line, ~r/\s+/)
            # df -h: Filesystem Size Used Avail Capacity ...
            %{
              total: Enum.at(parts, 1, "?"),
              used: Enum.at(parts, 2, "?"),
              available: Enum.at(parts, 3, "?"),
              use_pct: Enum.at(parts, 4, "?")
            }
        end

      _ ->
        %{total: "?", used: "?", available: "?", use_pct: "?"}
    end
  end

  defp host_uptime do
    case System.cmd("uptime", [], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      _ -> "unknown"
    end
  end

  # --- BEAM VM ---

  @doc "BEAM VM memory and process stats"
  def beam_stats do
    mem = :erlang.memory()

    %{
      total: mem[:total],
      processes: mem[:processes],
      ets: mem[:ets],
      system: mem[:system],
      process_count: :erlang.system_info(:process_count),
      schedulers: :erlang.system_info(:schedulers_online)
    }
  end

  # --- Workspaces ---

  @doc "Workspace health: is the group alive, is ServiceManager alive, recent errors"
  def workspace_stats do
    projects = BoomLooper.ProjectRegistry.list_projects()

    Enum.flat_map(projects, fn project ->
      workspaces = BoomLooper.ProjectRegistry.list_workspaces(project.id)

      Enum.map(workspaces, fn ws ->
        ws_id = BoomLooper.Workspace.workspace_id(ws.path)
        group_alive = BoomLooper.WorkspaceGroup.whereis(ws_id) != nil

        sm_alive = case Registry.lookup(BoomLooper.ServiceManagerRegistry, ws.path) do
          [{pid, _}] -> Process.alive?(pid)
          _ ->
            # Try virtual dir
            virtual_dir = Path.join([BoomLooper.Workspace.home_dir(), "workspaces", ws_id])
            case Registry.lookup(BoomLooper.ServiceManagerRegistry, virtual_dir) do
              [{pid, _}] -> Process.alive?(pid)
              _ -> false
            end
        end

        %{
          workspace_id: ws_id,
          project_name: project.name,
          workspace_name: ws.name,
          path: ws.path,
          group_alive: group_alive,
          service_manager_alive: sm_alive
        }
      end)
    end)
  end

  # --- Per Agent ---

  @doc "Per-agent resource breakdown: container, CLI process, GenServer"
  def agent_stats do
    agents = ChatAgent.list_agents()
    container_stats = docker_stats()
    cli_processes = claude_cli_processes()

    Enum.map(agents, fn agent ->
      container =
        if agent[:workspace_id] do
          container_stats[BoomLooper.Workspace.ServiceManager.service_container_name(agent.workspace_id, "workspace")]
        end
      pid_info = agent_process_info(agent.id)
      cli = find_cli_for_agent(cli_processes, agent.id)

      %{
        agent: agent,
        container: container,
        cli: cli,
        beam: pid_info
      }
    end)
  end

  @doc "Service container resource stats"
  def service_stats do
    container_stats = docker_stats()

    BoomLooper.Docker.list_containers(prefix: "bl-")
    |> Enum.map(fn container ->
      %{
        name: container.name,
        running: container.running,
        stats: container_stats[container.name]
      }
    end)
  end

  # --- Docker container stats ---

  defp docker_stats do
    case System.cmd("docker", [
           "stats", "--no-stream",
           "--format", "{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.PIDs}}"
         ], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.trim()
        |> String.split("\n", trim: true)
        |> Map.new(fn line ->
          case String.split(line, "\t") do
            [name, cpu, mem_usage, mem_pct, pids] ->
              {name, %{cpu: cpu, mem_usage: mem_usage, mem_pct: mem_pct, pids: pids}}
            _ ->
              {line, nil}
          end
        end)

      _ ->
        %{}
    end
  end

  # --- Claude CLI processes ---

  defp claude_cli_processes do
    case System.cmd("ps", ["aux"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.contains?(&1, "claude"))
        |> Enum.reject(&String.contains?(&1, "grep"))
        |> Enum.map(&parse_ps_line/1)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  @doc false
  def all_cli_processes do
    claude_cli_processes()
  end

  defp parse_ps_line(line) do
    parts = String.split(line, ~r/\s+/, parts: 11)

    case parts do
      [_user, pid, cpu, mem, _vsz, rss, _tty, _stat, _start, _time, command] ->
        %{
          pid: pid,
          cpu: cpu,
          mem: mem,
          rss: parse_int(rss),
          command: command
        }

      _ ->
        nil
    end
  end

  defp find_cli_for_agent(cli_processes, agent_id) do
    Enum.find(cli_processes, fn proc ->
      String.contains?(proc.command, agent_id)
    end)
  end

  defp agent_process_info(agent_id) do
    case Registry.lookup(BoomLooper.ChatAgentRegistry, agent_id) do
      [{pid, _}] ->
        case Process.info(pid, [:memory, :message_queue_len, :reductions, :heap_size]) do
          nil -> nil
          info -> Map.new(info)
        end

      [] ->
        nil
    end
  end

  defp parse_int(str) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> 0
    end
  end
end
