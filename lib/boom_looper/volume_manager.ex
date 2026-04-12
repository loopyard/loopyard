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

  @doc """
  List directory contents in a volume as structured entries.
  Returns {:ok, list} where each entry is %{type, size, path, name}.

  Options:
    - :depth — max find depth (default 1)
  """
  def tree(volume_name, path \\ ".", opts \\ []) do
    depth = Keyword.get(opts, :depth, 1)
    full_path = Path.join("/workspace", path)

    shell_quote = fn s -> "'" <> String.replace(s, "'", "'\"'\"'") <> "'" end

    cmd =
      "find #{shell_quote.(full_path)} -mindepth 1 -maxdepth #{depth} " <>
        "-not -path '*/.git*' -not -path '*/node_modules*' " <>
        "-not -path '*/_build*' -not -path '*/deps/*' " <>
        "-not -path '*/vendor/bundle*' -not -path '*/.next*' " <>
        "-not -path '*/dist*' -not -path '*/target*' " <>
        "-not -path '*/.venv*' -not -path '*/__pycache__*' " <>
        "-printf '%y\\t%s\\t%P\\n' 2>/dev/null | head -200"

    case find_container_for_volume(volume_name) do
      {:ok, container} ->
        case Docker.exec_in(container, cmd, timeout: 15_000) do
          {:ok, output} -> {:ok, parse_tree(output)}
          {:error, reason} -> {:error, reason}
        end

      :none ->
        {:error, :no_container}
    end
  end

  defp find_container_for_volume(volume_name) do
    case Regex.run(~r/^bl-([a-f0-9]+)-code$/, volume_name) do
      [_, workspace_id] ->
        container = "bl-#{workspace_id}-workspace-1"

        if Docker.container_running?(container) do
          {:ok, container}
        else
          :none
        end

      _ ->
        :none
    end
  end

  defp parse_tree(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      case String.split(line, "\t", parts: 3) do
        [type_char, size, path] ->
          type = if type_char == "d", do: :dir, else: :file

          %{
            type: type,
            size: parse_int(size),
            path: path,
            name: Path.basename(path)
          }

        _ ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(fn e -> {if(e.type == :dir, do: 0, else: 1), e.name} end)
  end

  defp parse_int(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> 0
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
