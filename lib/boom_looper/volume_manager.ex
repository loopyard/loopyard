defmodule BoomLooper.VolumeManager do
  @moduledoc """
  Manages Docker volumes for workspaces.

  Each workspace gets a named volume for code storage. Code is cloned from git
  into the volume, eliminating bind mount issues (Unix sockets, file watchers,
  platform binaries).

  File I/O operations are delegated to `BoomLooper.VolumeIO`.
  Clone operations are delegated to `BoomLooper.VolumeCloner`.
  """

  require Logger

  alias BoomLooper.Docker

  @clone_timeout 300_000  # 5 minutes

  # Delegate file I/O to VolumeIO for backwards compatibility
  defdelegate read_file(volume_name, path), to: BoomLooper.VolumeIO
  defdelegate write_file(volume_name, path, content), to: BoomLooper.VolumeIO
  defdelegate copy_to_volume(volume_name, source_path), to: BoomLooper.VolumeIO
  defdelegate copy_to_volume(volume_name, source_path, opts), to: BoomLooper.VolumeIO

  # Delegate clone operations to VolumeCloner for backwards compatibility
  defdelegate clone_into_volume(volume_name, git_url), to: BoomLooper.VolumeCloner
  defdelegate clone_into_volume(volume_name, git_url, opts), to: BoomLooper.VolumeCloner

  # --- Volume Operations ---

  @doc """
  Create a named Docker volume.
  Returns :ok if created or already exists.
  """
  def create_volume(volume_name) do
    case Docker.docker(["volume", "create", volume_name]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Delete a named Docker volume.
  """
  def delete_volume(volume_name) do
    case Docker.docker(["volume", "rm", "-f", volume_name]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Check if a volume exists.
  """
  def volume_exists?(volume_name) do
    case Docker.docker(["volume", "inspect", volume_name]) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  @doc """
  List all volumes for a workspace.
  Returns volumes matching bl-{workspace_id}* pattern.
  """
  def list_workspace_volumes(workspace_id) do
    case Docker.docker(["volume", "ls", "--format", "{{.Name}}"]) do
      {:ok, output} ->
        volumes = output
        |> String.trim()
        |> String.split("\n", trim: true)
        |> Enum.filter(fn name ->
          String.starts_with?(name, "bl-#{workspace_id}")
        end)
        |> Enum.map(fn name -> volume_info(name) end)
        |> Enum.reject(&is_nil/1)

        {:ok, volumes}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  List ALL bl-* volumes — name + parsed purpose only, no `du` shell-out.

  Use this for cluster overviews where you'd otherwise spawn one Alpine
  container per volume just to measure size. If you need sizes, fetch
  them separately for the volumes the user actually opens.
  """
  def list_all_volumes do
    case Docker.docker(["volume", "ls", "--filter", "name=bl-", "--format", "{{.Name}}"]) do
      {:ok, output} ->
        output
        |> String.trim()
        |> String.split("\n", trim: true)
        |> Enum.map(&volume_summary/1)

      _ ->
        []
    end
  end

  @doc """
  Cheap volume summary — name + parsed purpose. No `docker volume inspect`,
  no `du`. Pairs with `list_all_volumes/0`.
  """
  def volume_summary(name) do
    {type, service, description} = parse_volume_purpose(name)
    %{name: name, type: type, service: service, description: description}
  end

  @doc """
  Get volume info: name, size, mount point, related service.
  """
  def volume_info(volume_name) do
    case Docker.docker(["volume", "inspect", volume_name, "--format", "{{json .}}"]) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, data} ->
            size = get_volume_size(volume_name)
            {type, service, description} = parse_volume_purpose(volume_name)

            %{
              name: volume_name,
              mount_point: data["Mountpoint"],
              driver: data["Driver"],
              created_at: data["CreatedAt"],
              size: size,
              type: type,
              service: service,
              description: description
            }
          _ -> nil
        end
      _ -> nil
    end
  end

  # Parse volume name to determine its purpose and related service
  defp parse_volume_purpose(name) do
    cond do
      Regex.match?(~r/^bl-[a-f0-9]+-code$/, name) ->
        {:code, "workspace", "Project source code"}

      String.contains?(name, "cache") ->
        {:cache, "workspace", "Build cache (~/.cache)"}

      String.contains?(name, "deps") ->
        {:deps, "workspace", "Dependencies (/deps)"}

      Regex.match?(~r/^(.+)-data-[a-f0-9]+$/, name) ->
        [_, service] = Regex.run(~r/^(.+)-data-[a-f0-9]+$/, name)
        description = case service do
          "postgres" -> "PostgreSQL database"
          "redis" -> "Redis data"
          "minio" -> "MinIO object storage"
          "mysql" -> "MySQL database"
          "mongo" -> "MongoDB data"
          _ -> "#{service} data"
        end
        {:data, service, description}

      true ->
        {:other, nil, "Unknown volume"}
    end
  end

  defp get_volume_size(volume_name) do
    case Docker.docker([
      "run", "--rm",
      "-v", "#{volume_name}:/vol",
      "alpine", "du", "-sh", "/vol"
    ], timeout: 10_000) do
      {:ok, output} ->
        case String.split(String.trim(output), ~r/\s+/, parts: 2) do
          [size | _] -> size
          _ -> "unknown"
        end
      _ -> "unknown"
    end
  end

  @doc """
  List directory contents in a volume.
  """
  def volume_ls(volume_name, path \\ "/") do
    case Docker.docker([
      "run", "--rm",
      "-v", "#{volume_name}:/vol",
      "alpine", "ls", "-la", "/vol#{path}"
    ]) do
      {:ok, output} -> {:ok, output}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Delete all code-*, cache-*, and deps-* volumes not associated with an active workspace.
  Returns {:ok, deleted_count} or {:error, reason}.
  """
  def prune_orphaned_volumes do
    active_ids = BoomLooper.ProjectRegistry.list_projects()
    |> Enum.flat_map(fn p -> BoomLooper.ProjectRegistry.list_workspaces(p.id) end)
    |> Enum.map(fn ws -> BoomLooper.Workspace.workspace_id(ws.path) end)
    |> MapSet.new()

    case Docker.docker(["volume", "ls", "--format", "{{.Name}}"]) do
      {:ok, output} ->
        volumes = output |> String.trim() |> String.split("\n", trim: true)

        orphans = Enum.filter(volumes, fn name ->
          case Regex.run(~r/^(?:code|cache|deps|bl-.*_cache)-([a-f0-9]{4})$/, name) do
            [_, ws_id] -> ws_id not in active_ids
            nil ->
              case Regex.run(~r/^bl-([a-f0-9]{4})_/, name) do
                [_, ws_id] -> ws_id not in active_ids
                nil -> false
              end
          end
        end)

        deleted = Enum.count(orphans, fn name ->
          match?({:ok, _}, Docker.docker(["volume", "rm", "-f", name]))
        end)

        Logger.info("[VolumeManager] Pruned #{deleted}/#{length(orphans)} orphaned volumes")
        {:ok, deleted}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Clone a git repository into a running workspace container.
  Faster than clone_into_volume because it uses the already-running container.

  Options:
    - branch: branch to checkout (default: main)
    - token: GitHub token for auth (optional)
  """
  def clone_in_container(workspace_id, git_url, opts \\ []) do
    branch = Keyword.get(opts, :branch, "main")
    token = Keyword.get(opts, :token)
    container = "bl-#{workspace_id}-workspace-1"

    auth_url = if token, do: BoomLooper.VolumeCloner.inject_token(git_url, token), else: git_url

    clone_cmd = "git clone --branch #{branch} --depth 1 '#{auth_url}' /workspace"

    case Docker.docker(["exec", container, "sh", "-c", clone_cmd], timeout: @clone_timeout) do
      {:ok, output} -> {:ok, output}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Pull latest changes in a volume (git pull).
  Requires workspace container to be running.
  """
  def pull_in_container(workspace_id) do
    container = "bl-#{workspace_id}-workspace-1"

    case Docker.docker(["exec", container, "git", "-C", "/workspace", "pull"]) do
      {:ok, output} -> {:ok, output}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Check if a volume has code (not empty).
  """
  def volume_has_code?(volume_name) do
    case Docker.docker([
      "run", "--rm",
      "-v", "#{volume_name}:/workspace",
      "alpine", "sh", "-c", "test -d /workspace/.git && echo yes || echo no"
    ]) do
      {:ok, output} -> String.trim(output) == "yes"
      {:error, _} -> false
    end
  end

  @doc """
  List files in a volume matching a glob pattern.
  """
  def glob(volume_name, pattern) do
    case Docker.docker([
      "run", "--rm",
      "-v", "#{volume_name}:/workspace",
      "alpine", "sh", "-c", "find /workspace -name '#{pattern}' -type f 2>/dev/null | head -100"
    ]) do
      {:ok, output} ->
        files = output
        |> String.trim()
        |> String.split("\n", trim: true)
        |> Enum.map(&String.replace(&1, "/workspace/", ""))
        {:ok, files}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- Volume Naming ---

  @doc """
  Generate volume name for workspace code.
  """
  def code_volume_name(workspace_id) do
    "bl-#{workspace_id}-code"
  end

  @doc """
  Generate volume name for workspace cache.
  """
  def cache_volume_name(workspace_id) do
    "bl-#{workspace_id}-cache"
  end
end
