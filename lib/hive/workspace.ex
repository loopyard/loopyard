defmodule Hive.Workspace do
  @moduledoc """
  Workspace configuration for a project directory.
  Lives as `.hive/workspace.json` in the project root.
  Written by setup agents, read by Hive when spawning future agents.
  """

  @config_dir ".hive"
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
    %__MODULE__{
      name: data["name"],
      dockerfile: data["dockerfile"],
      services: (data["services"] || []) |> Enum.map(&parse_service/1),
      processes: (data["processes"] || []) |> Enum.map(&parse_process/1),
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
      env: s["env"] || %{},
      volumes: s["volumes"] || [],
      ports: s["ports"] || %{}
    }
  end

  defp parse_process(p) when is_map(p) do
    %{
      name: p["name"],
      command: p["command"]
    }
  end

  defp service_to_map(s) do
    %{
      "name" => s.name,
      "image" => s.image,
      "env" => s.env,
      "volumes" => s.volumes,
      "ports" => s.ports
    }
  end

  defp process_to_map(p) do
    %{
      "name" => p.name,
      "command" => p.command
    }
  end
end
