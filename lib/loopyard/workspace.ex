defmodule Loopyard.Workspace do
  @moduledoc """
  Workspace configuration for a project directory.
  Stores METADATA only: project name, system prompt, git info.

  Infrastructure (Dockerfile, docker-compose.yml) is written directly by agents
  via loopyard-container tools. This module does NOT handle infrastructure.

  Lives as `.loopyard/repo/workspace.json` in the project root.
  """

  @config_dir ".loopyard/repo"
  @config_file "workspace.json"

  defstruct [
    # Display name in the UI
    :name,
    # System prompt fragment for future agents
    :system_prompt,
    # Git repository URL (e.g., "git@github.com:owner/repo.git")
    :git_url,
    # Branch name (e.g., "main")
    :branch
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
    case Loopyard.VolumeManager.read_file(volume_name, ".loopyard/repo/workspace.json") do
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
    Loopyard.VolumeManager.write_file(volume_name, ".loopyard/repo/workspace.json", json)
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
  Loopyard's home directory for user-level data (secrets, SSH keys, etc.).
  Defaults to `~/.loopyard`, overridable with `LOOPYARD_HOME` env var.
  """
  def home_dir do
    case System.get_env("LOOPYARD_HOME") do
      val when val in [nil, ""] -> Path.join(System.user_home!(), ".loopyard")
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
  Check if the **compose** workspace service container is running (the
  `loopyard-<ws>-workspace-1` container that comes up with the preview
  cluster). When true, agents should use container tools (exec, read_file)
  — not host-side file access.

  NOTE: this is *not* the same as "can the agent work" — see `working?/1`.
  Most of the time an agent works against the cheap `WorkContainer`, with no
  compose cluster running at all.
  """
  def container_running?(workspace_id) do
    container =
      Loopyard.Workspace.ServiceManager.service_container_name(workspace_id, "workspace")

    Loopyard.Docker.container_running?(container)
  end

  @doc """
  Is the workspace in a **working** state — i.e. does it have *some*
  code-mounted container an agent can exec into? True if either the compose
  workspace service container OR the cheap `WorkContainer` is up.

  This is the north-star default (D10): working doesn't require the dev/preview
  cluster. The preview cluster (`status: :running`) is a separate, opt-in thing.
  """
  def working?(workspace_id) do
    container_running?(workspace_id) or
      Loopyard.Workspace.WorkContainer.running?(workspace_id)
  end

  @doc """
  Ensure the workspace can be worked on *right now*, cheaply.

  If the compose workspace container is already up (preview running), that's
  enough. Otherwise bring up the cheap `WorkContainer` (no project image, no
  services). Returns `{:ok, container_name}` — the container an agent should
  exec into — or `{:error, reason}`.
  """
  def ensure_working(workspace_id) do
    cond do
      container_running?(workspace_id) ->
        {:ok, Loopyard.Workspace.ServiceManager.service_container_name(workspace_id, "workspace")}

      # Never drive a Docker create/build for a workspace we don't know about.
      # Booting a container for a phantom id otherwise blocks the caller for
      # tens of seconds (e.g. a tool exec against a never-provisioned id). Fail
      # fast — there's nothing to self-heal.
      is_nil(Loopyard.ProjectRegistry.get_workspace(workspace_id)) ->
        {:error, "workspace #{workspace_id} is not registered — nothing to start"}

      true ->
        Loopyard.Workspace.WorkContainer.ensure_up(workspace_id)
    end
  end

  @doc """
  The container an agent should exec into for this workspace, preferring the
  full compose workspace container when the preview cluster is up (it has the
  project's real toolchain) and otherwise the cheap `WorkContainer`.

  Returns `{:ok, name}` when one is running, or `{:error, :not_working}` when
  neither is up (caller should `ensure_working/1` first).
  """
  def agent_container(workspace_id) do
    cond do
      container_running?(workspace_id) ->
        {:ok, Loopyard.Workspace.ServiceManager.service_container_name(workspace_id, "workspace")}

      Loopyard.Workspace.WorkContainer.running?(workspace_id) ->
        {:ok, Loopyard.Workspace.WorkContainer.container_name(workspace_id)}

      true ->
        {:error, :not_working}
    end
  end

  @doc """
  Returns true when the workspace's setup saga has finished (`phase: :ready`).
  False during pending / running / failed states.

  Pre-feature workspaces are normalized to `phase: :ready` by the registry,
  so this returns true for legacy entries.
  """
  def ready?(%{setup: %{phase: :ready}}), do: true
  def ready?(%{setup: _}), do: false
  def ready?(_), do: true

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

  @doc """
  The workstation (identity) a workspace belongs to — the creds/home its agents
  inherit. Reads the workspace's recorded `:workstation_id`; falls back to the
  current identity for legacy workspaces created before the field existed. Accepts
  a workspace map or a workspace id.
  """
  def workstation_id(%{} = ws), do: ws[:workstation_id] || Loopyard.Workstation.current()

  def workstation_id(ws_id) when is_binary(ws_id) do
    case Loopyard.WorkspaceRegistry.get_workspace(ws_id) do
      %{} = ws -> workstation_id(ws)
      _ -> Loopyard.Workstation.current()
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
    case Loopyard.ProjectRegistry.get_workspace(workspace_id) do
      %{volume: vol} when is_binary(vol) -> vol
      # Always use the canonical naming. The old fallback "code-#{workspace_id}"
      # created ghost volumes that never got cleaned up because cleanup uses
      # VolumeManager.code_volume_name/1, which is prefix-scoped per environment.
      _ -> Loopyard.VolumeManager.code_volume_name(workspace_id)
    end
  end
end
