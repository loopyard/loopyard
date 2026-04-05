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
    :git_url,       # Git repository URL (e.g., "git@github.com:owner/repo.git")
    :branch,        # Branch name (e.g., "main")
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

  @doc "Load workspace config from a Docker volume. Returns {:ok, workspace} or :none"
  def load_from_volume(volume_name) do
    case BoomLooper.VolumeManager.read_file(volume_name, ".boomlooper/repo/workspace.json") do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, data} -> {:ok, from_map(data)}
          {:error, reason} -> {:error, "Invalid workspace JSON: #{inspect(reason)}"}
        end

      {:error, :not_found} ->
        :none

      {:error, reason} ->
        {:error, "Failed to read workspace config from volume: #{inspect(reason)}"}
    end
  end

  @doc "Save workspace config to a Docker volume."
  def save_to_volume(volume_name, %__MODULE__{} = workspace) do
    json = workspace |> to_map() |> Jason.encode!(pretty: true)
    BoomLooper.VolumeManager.write_file(volume_name, ".boomlooper/repo/workspace.json", json)
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

    # Split: services with `image` are stock services, those without are processes (legacy format)
    {stock_from_services, legacy_svc_as_procs} =
      Enum.split_with(raw_services, fn s -> s.image != nil end)

    # Convert legacy service entries (no image) to process format
    procs_from_services = Enum.map(legacy_svc_as_procs, fn s ->
      # Look up the original command from raw data since parse_service doesn't include it
      raw = Enum.find(data["services"] || [], fn raw -> raw["name"] == s.name end)
      %{name: s.name, command: raw["command"], ports: s.ports}
    end)

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
      git_url: data["git_url"],
      branch: data["branch"],
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
      "git_url" => ws.git_url,
      "branch" => ws.branch,
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

  @doc "Generate a workspace ID from git URL and branch (for volume-based workspaces)"
  def workspace_id_from_git(git_url, branch) do
    "#{normalize_git_url(git_url)}:#{branch}"
    |> :erlang.phash2(0xFFFF)
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(4, "0")
  end

  @doc "Generate a project ID from git URL"
  def project_id_from_git(git_url) do
    normalize_git_url(git_url)
    |> :erlang.phash2(0xFFFF)
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(4, "0")
  end

  @doc "Normalize a git URL for consistent hashing"
  def normalize_git_url(url) do
    url
    |> String.downcase()
    |> String.replace(~r/\.git$/, "")
    |> String.replace(~r/^https?:\/\//, "")
    |> String.replace(~r/^git@/, "")
    |> String.replace(":", "/")
  end

  # --- Private ---

  defp parse_service(s) when is_map(s) do
    %{
      name: s["name"],
      image: s["image"],
      env: s["env"] || %{},
      volumes: s["volumes"] || [],
      ports: normalize_ports(s["ports"])
    }
  end

  defp parse_process(p) when is_map(p) do
    %{
      name: p["name"],
      command: p["command"],
      ports: normalize_ports(p["ports"])
    }
  end

  defp normalize_ports(nil), do: []
  defp normalize_ports(ports) when is_list(ports) do
    ports |> Enum.map(&to_string/1) |> Enum.reject(&(&1 == ""))
  end
  defp normalize_ports(port) when is_integer(port), do: [to_string(port)]
  defp normalize_ports(port) when is_binary(port) and port != "", do: [port]
  defp normalize_ports(port) when is_binary(port), do: []
  defp normalize_ports(%{} = ports) when map_size(ports) == 0, do: []
  defp normalize_ports(ports) when is_map(ports) do
    # Extract keys (port numbers), not values (which may be empty from old bug)
    Map.keys(ports) |> Enum.map(&to_string/1) |> Enum.reject(&(&1 == ""))
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
