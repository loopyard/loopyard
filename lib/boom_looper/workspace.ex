defmodule BoomLooper.Workspace do
  @moduledoc """
  Workspace configuration for a project directory.
  Lives as `.boomlooper/repo/workspace.json` in the project root.
  Written by setup agents, read by BoomLooper when spawning future agents.
  """

  @config_dir ".boomlooper/repo"
  @config_file "workspace.json"

  defstruct [
    :name,
    :dockerfile,
    services: [],
    processes: [],
    env_vars: %{},
    system_prompt: nil
  ]

  @doc "Path to the workspace config file for a given project directory"
  def config_path(project_dir) do
    Path.join([project_dir, @config_dir, @config_file])
  end

  @doc "Load workspace config from a project directory. Returns {:ok, workspace} or :none"
  def load(project_dir) do
    path = config_path(project_dir)

    case File.read(path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, data} -> {:ok, from_map(data)}
          {:error, reason} -> {:error, "Invalid workspace JSON: #{inspect(reason)}"}
        end

      {:error, :enoent} ->
        :none

      {:error, reason} ->
        {:error, "Failed to read workspace config: #{inspect(reason)}"}
    end
  end

  @doc "Save workspace config to a project directory"
  def save(project_dir, %__MODULE__{} = workspace) do
    dir = Path.join(project_dir, @config_dir)
    File.mkdir_p!(dir)

    path = config_path(project_dir)
    json = workspace |> to_map() |> Jason.encode!(pretty: true)
    File.write(path, json)
  end

  @doc "Build a Workspace struct from a decoded JSON map"
  def from_map(data) when is_map(data) do
    raw_services = (data["services"] || []) |> Enum.map(&parse_service/1)
    legacy_processes = (data["processes"] || []) |> Enum.map(&parse_process/1)

    # Split: services with `image` are stock services, those with `command` (no image) are processes
    {stock_from_services, procs_from_services} =
      Enum.split_with(raw_services, fn s -> s.image != nil end)

    # Merge legacy processes, deduplicating by name against procs_from_services
    all_processes =
      Enum.reduce(legacy_processes, procs_from_services, fn proc, acc ->
        if Enum.any?(acc, fn p -> p.name == proc.name end) do
          acc
        else
          acc ++ [%{name: proc.name, command: proc.command, ports: proc[:ports] || []}]
        end
      end)

    %__MODULE__{
      name: data["name"],
      dockerfile: data["dockerfile"],
      services: stock_from_services,
      processes: all_processes,
      env_vars: data["env_vars"] || %{},
      system_prompt: data["system_prompt"]
    }
  end

  @doc "Convert a Workspace struct to a JSON-serializable map"
  def to_map(%__MODULE__{} = ws) do
    %{
      "name" => ws.name,
      "dockerfile" => ws.dockerfile,
      "services" => Enum.map(ws.services, &service_to_map/1),
      "processes" => Enum.map(ws.processes, &process_to_map/1),
      "env_vars" => ws.env_vars,
      "system_prompt" => ws.system_prompt
    }
  end

  @doc """
  BoomLooper's home directory for user-level data (secrets, SSH keys, etc.).
  Defaults to `~/.boomlooper`, overridable with `BOOMLOOPER_HOME` env var.
  """
  def home_dir do
    System.get_env("BOOMLOOPER_HOME") || Path.join(System.user_home!(), ".boomlooper")
  end

  @doc "Generate a workspace ID from a project directory path (for naming service containers)"
  def workspace_id(project_dir) do
    project_dir
    |> Path.expand()
    |> :erlang.phash2(0xFFFF)
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(4, "0")
  end

  # --- Private ---

  defp parse_service(s) when is_map(s) do
    %{
      name: s["name"],
      image: s["image"],
      command: s["command"],
      env: s["env"] || %{},
      volumes: s["volumes"] || [],
      ports: s["ports"] || %{}
    }
  end

  defp parse_process(p) when is_map(p) do
    %{
      name: p["name"],
      command: p["command"],
      ports: p["ports"] || []
    }
  end

  defp service_to_map(s) do
    map = %{
      "name" => s.name,
      "image" => s.image,
      "env" => s.env,
      "volumes" => s.volumes,
      "ports" => s.ports
    }

    map
  end

  defp process_to_map(p) do
    map = %{"name" => p.name, "command" => p.command}
    if p[:ports] && p[:ports] != [], do: Map.put(map, "ports", p.ports), else: map
  end

end
