defmodule BoomLooper.Workspace do
  @moduledoc """
  Workspace configuration for a project directory.
  Stores METADATA only: project name, system prompt, git info.

  Infrastructure (Dockerfile, docker-compose.yml) is written directly by agents
  via boom-looper-container tools. This module does NOT handle infrastructure.

  Lives as `.boomlooper/repo/workspace.json` in the project root.
  """

  @config_dir ".boomlooper/repo"
  @config_file "workspace.json"

  defstruct [
    :name,          # Display name in the UI
    :system_prompt, # System prompt fragment for future agents
    :git_url,       # Git repository URL (e.g., "git@github.com:owner/repo.git")
    :branch         # Branch name (e.g., "main")
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
    %__MODULE__{
      name: data["name"],
      system_prompt: data["system_prompt"],
      git_url: data["git_url"],
      branch: data["branch"]
    }
  end

  @doc "Convert a Workspace struct to a JSON-serializable map"
  def to_map(%__MODULE__{} = ws) do
    %{
      "name" => ws.name,
      "system_prompt" => ws.system_prompt,
      "git_url" => ws.git_url,
      "branch" => ws.branch
    }
  end

  @doc """
  BoomLooper's home directory for user-level data (secrets, SSH keys, etc.).
  Defaults to `~/.boomlooper`, overridable with `BOOMLOOPER_HOME` env var.
  """
  def home_dir do
    case System.get_env("BOOMLOOPER_HOME") do
      val when val in [nil, ""] -> Path.join(System.user_home!(), ".boomlooper")
      path -> path
    end
  end

  @doc """
  The virtual dir where compose files, Dockerfiles, and agent logs live
  for a workspace. This is the ONLY correct way to get this path.
  """
  def compose_dir(workspace_id) do
    Path.join([home_dir(), "workspaces", workspace_id])
  end

  @doc """
  Resolve workspace ID from a project directory path.

  For volume-based workspaces (paths like `.../workspaces/{id}`), extracts the ID directly.
  For bind-mount projects, generates a hash-based ID.
  """
  def workspace_id(project_dir) do
    # Check if this is a volume-based workspace path (e.g., .../workspaces/6e79)
    workspaces_base = Path.join(home_dir(), "workspaces")
    expanded = Path.expand(project_dir)

    if String.starts_with?(expanded, workspaces_base) do
      # Extract the workspace ID from the path
      expanded
      |> Path.relative_to(workspaces_base)
      |> Path.split()
      |> List.first()
    else
      # Fall back to hash-based ID for bind-mount projects
      hash_workspace_id(expanded)
    end
  end

  @doc "Generate a hash-based workspace ID (for bind-mount projects only)"
  def hash_workspace_id(project_dir) do
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

  @doc """
  Get the volume name for a workspace.
  Looks up the workspace in the registry to find the actual volume name.
  Falls back to `code-{workspace_id}` for backwards compatibility.
  """
  def volume_name_for(workspace_id) do
    case BoomLooper.ProjectRegistry.get_workspace(workspace_id) do
      %{volume: vol} when is_binary(vol) -> vol
      # Always use the canonical naming. The old fallback "code-#{workspace_id}"
      # created ghost volumes that never got cleaned up because cleanup uses
      # VolumeManager.code_volume_name/1 which returns "bl-#{ws_id}-code".
      _ -> BoomLooper.VolumeManager.code_volume_name(workspace_id)
    end
  end
end
