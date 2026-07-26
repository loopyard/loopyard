defmodule Loopyard.SystemStats do
  @moduledoc """
  Collects resource usage stats at three levels:
  1. Host system — total RAM, CPU, disk
  2. This app — BEAM VM memory, process counts
  3. Per agent — Docker container, Claude CLI process, GenServer

  Every public function in this module is **independently callable** and
  represents one slice of data. LiveViews mount with skeletons, then load
  each slice in its own `Task.start` so slow shell-outs (`docker stats`,
  `ps aux`, `vm_stat`) don't block the page render or each other.

  Don't add a "load everything" function — that's what mount used to do
  and it made the page take seconds to paint.

  ## Why structs

  The slice functions return **typed structs**, not raw maps. We learned
  the hard way that returning `%{running: true, health: :healthy}` and
  later renaming the fields silently broke 6 sidebar tests — Elixir
  happily lets you read missing keys from a map (returning nil), so
  drift gets discovered weeks later by a confused user. Structs make
  field renames an immediate compile error.

  If you add a new field to one of these structs, every consumer that
  pattern-matches on it (templates do `@host_cpu.cores`) breaks at
  compile time instead of silently rendering empty.
  """

  defmodule HostCpu do
    @moduledoc "Host CPU stats. Returned by `SystemStats.host_cpu/0`."
    @enforce_keys [:cores, :load_avg]
    defstruct [:cores, :load_avg]

    @type t :: %__MODULE__{cores: pos_integer(), load_avg: [float()]}
  end

  defmodule HostMemory do
    @moduledoc "Host RAM stats. Returned by `SystemStats.host_memory/0`."
    @enforce_keys [:total, :used, :free]
    defstruct [:total, :used, :free, :inactive, :compressed]

    @type t :: %__MODULE__{
            total: non_neg_integer(),
            used: non_neg_integer(),
            free: non_neg_integer(),
            inactive: non_neg_integer() | nil,
            compressed: non_neg_integer() | nil
          }
  end

  defmodule HostDisk do
    @moduledoc "Host disk stats from `df -h /`. Returned by `SystemStats.host_disk/0`."
    @enforce_keys [:total, :used, :available, :use_pct]
    defstruct [:total, :used, :available, :use_pct]

    @type t :: %__MODULE__{
            total: String.t(),
            used: String.t(),
            available: String.t(),
            use_pct: String.t()
          }
  end

  defmodule BeamStats do
    @moduledoc "BEAM VM stats. Returned by `SystemStats.beam_stats/0`."
    @enforce_keys [:total, :processes, :ets, :system, :process_count, :schedulers]
    defstruct [:total, :processes, :ets, :system, :process_count, :schedulers]

    @type t :: %__MODULE__{
            total: non_neg_integer(),
            processes: non_neg_integer(),
            ets: non_neg_integer(),
            system: non_neg_integer(),
            process_count: non_neg_integer(),
            schedulers: pos_integer()
          }
  end

  alias Loopyard.ChatAgent

  # --- Host System (each slice is one shell-out, callable in isolation) ---

  @doc "Host CPU info: core count and load average. Single sysctl call."
  @spec host_cpu() :: HostCpu.t()
  def host_cpu do
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

    %HostCpu{cores: cores, load_avg: load}
  end

  @doc "Host RAM stats — vm_stat on macOS, memsup (:os_mon) elsewhere."
  @spec host_memory() :: HostMemory.t()
  def host_memory do
    case :os.type() do
      {:unix, :darwin} -> darwin_memory()
      _ -> memsup_memory()
    end
  end

  # Non-macOS (Linux CI, servers): :os_mon's memsup, no shell-out. vm_stat
  # doesn't exist there — calling it raised :enoent and crashed the async task.
  defp memsup_memory do
    data = :memsup.get_system_memory_data()
    total = Keyword.get(data, :system_total_memory, 0)
    available = Keyword.get(data, :available_memory) || Keyword.get(data, :free_memory, 0)

    %HostMemory{
      total: total,
      used: max(total - available, 0),
      free: available,
      inactive: 0,
      compressed: 0
    }
  rescue
    _ -> %HostMemory{total: 0, used: 0, free: 0, inactive: 0, compressed: 0}
  catch
    :exit, _ -> %HostMemory{total: 0, used: 0, free: 0, inactive: 0, compressed: 0}
  end

  defp darwin_memory do
    # macOS: vm_stat for memory breakdown
    case System.cmd("vm_stat", [], stderr_to_stdout: true) do
      {output, 0} ->
        # macOS default on Apple Silicon (16KB)
        page_size = 16_384

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

        %HostMemory{
          total: total,
          used: used,
          free: free,
          inactive: inactive,
          compressed: compressed
        }

      _ ->
        %HostMemory{total: 0, used: 0, free: 0, inactive: 0, compressed: 0}
    end
  end

  @doc "Host disk usage for /. Single df call."
  @spec host_disk() :: HostDisk.t()
  def host_disk do
    case System.cmd("df", ["-h", "/"], stderr_to_stdout: true) do
      {output, 0} ->
        lines = String.split(output, "\n", trim: true)

        case Enum.at(lines, 1) do
          nil ->
            %HostDisk{total: "?", used: "?", available: "?", use_pct: "?"}

          line ->
            parts = String.split(line, ~r/\s+/)
            # df -h: Filesystem Size Used Avail Capacity ...
            %HostDisk{
              total: Enum.at(parts, 1, "?"),
              used: Enum.at(parts, 2, "?"),
              available: Enum.at(parts, 3, "?"),
              use_pct: Enum.at(parts, 4, "?")
            }
        end

      _ ->
        %HostDisk{total: "?", used: "?", available: "?", use_pct: "?"}
    end
  end

  @doc "Host uptime string from `uptime`."
  def host_uptime do
    case System.cmd("uptime", [], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      _ -> "unknown"
    end
  end

  # --- BEAM VM ---

  @doc "BEAM VM memory and process stats"
  @spec beam_stats() :: BeamStats.t()
  def beam_stats do
    mem = :erlang.memory()

    %BeamStats{
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
    projects = Loopyard.ProjectRegistry.list_projects()

    Enum.flat_map(projects, fn project ->
      workspaces = Loopyard.ProjectRegistry.list_workspaces(project.id)

      Enum.map(workspaces, fn ws ->
        ws_id = Loopyard.Workspace.workspace_id(ws.path)
        group_alive = Loopyard.WorkspaceGroup.whereis(ws_id) != nil

        sm_alive =
          case Registry.lookup(Loopyard.ServiceManagerRegistry, ws.path) do
            [{pid, _}] ->
              Process.alive?(pid)

            _ ->
              # Try virtual dir
              virtual_dir = Loopyard.Workspace.compose_dir(ws_id)

              case Registry.lookup(Loopyard.ServiceManagerRegistry, virtual_dir) do
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

  @doc """
  Per-agent resource breakdown: container, CLI process, GenServer.

  Accepts pre-fetched container stats and CLI processes so callers can
  fetch them once and reuse. Pass `%{}` and `[]` if you don't have them
  yet (the per-agent rows will just be missing those columns).
  """
  def agent_stats(container_stats \\ %{}, cli_processes \\ []) do
    Enum.map(ChatAgent.list_agents(), fn agent ->
      container =
        if agent[:workspace_id] do
          container_stats[
            Loopyard.Workspace.ServiceManager.service_container_name(
              agent.workspace_id,
              "workspace"
            )
          ]
        end

      %{
        agent: agent,
        container: container,
        cli: find_cli_for_agent(cli_processes, agent.id),
        beam: agent_process_info(agent.id)
      }
    end)
  end

  @doc "Service container resource stats. Accepts pre-fetched docker stats."
  def service_stats(container_stats \\ %{}) do
    Loopyard.Docker.list_containers(prefix: "loopyard-")
    |> Enum.map(fn container ->
      %{
        name: container.name,
        running: container.running,
        stats: container_stats[container.name]
      }
    end)
  end

  # --- Docker container stats ---

  @doc """
  Per-container resource stats from `docker stats --no-stream`. SLOW —
  one shell-out, but `docker stats` itself takes ~1-2s to gather samples.
  Returns a map keyed by container name. Call this once and pass it to
  `agent_stats/2` and `service_stats/1`.
  """
  def docker_container_stats do
    case Loopyard.Docker.docker([
           "stats",
           "--no-stream",
           "--format",
           "{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.PIDs}}"
         ]) do
      {:ok, output} ->
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

  @doc """
  All Claude CLI processes from `ps aux`. SLOW — one full ps walk.
  """
  def claude_cli_processes do
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
    case Registry.lookup(Loopyard.ChatAgentRegistry, agent_id) do
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
