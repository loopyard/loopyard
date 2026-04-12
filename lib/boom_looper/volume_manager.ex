defmodule BoomLooper.VolumeManager do
  @moduledoc """
  Manages Docker volumes for workspaces.

  Each workspace gets a named volume for code storage. Code is cloned from git
  into the volume, eliminating bind mount issues (Unix sockets, file watchers,
  platform binaries).
  """

  require Logger

  alias BoomLooper.Docker

  @clone_timeout 300_000  # 5 minutes

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
  # Patterns:
  #   bl-{ws_id}-code           → workspace code
  #   bl-{ws_id}_cache-{ws_id}  → workspace cache
  #   bl-{ws_id}_deps-{ws_id}   → workspace deps
  #   {service}-data-{ws_id}    → service data (postgres, redis, etc.)
  defp parse_volume_purpose(name) do
    cond do
      # Code volume: bl-XXXX-code
      Regex.match?(~r/^bl-[a-f0-9]+-code$/, name) ->
        {:code, "workspace", "Project source code"}

      # Cache volume: bl-XXXX_cache-XXXX or cache-XXXX
      String.contains?(name, "cache") ->
        {:cache, "workspace", "Build cache (~/.cache)"}

      # Deps volume: bl-XXXX_deps-XXXX or deps-XXXX
      String.contains?(name, "deps") ->
        {:deps, "workspace", "Dependencies (/deps)"}

      # Service data volume: {service}-data-{ws_id}
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
    # Get size by running du in a container
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
    # Find active workspace IDs
    active_ids = BoomLooper.ProjectRegistry.list_projects()
    |> Enum.flat_map(fn p -> BoomLooper.ProjectRegistry.list_workspaces(p.id) end)
    |> Enum.map(fn ws -> BoomLooper.Workspace.workspace_id(ws.path) end)
    |> MapSet.new()

    # List all Docker volumes
    case Docker.docker(["volume", "ls", "--format", "{{.Name}}"]) do
      {:ok, output} ->
        volumes = output |> String.trim() |> String.split("\n", trim: true)

        orphans = Enum.filter(volumes, fn name ->
          case Regex.run(~r/^(?:code|cache|deps|bl-.*_cache)-([a-f0-9]{4})$/, name) do
            [_, ws_id] -> ws_id not in active_ids
            nil ->
              # Also match compose-managed volumes like bl-XXXX_cache-XXXX
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

  # --- Clone Operations ---

  @doc """
  Clone a git repository into a volume.

  Options:
    - branch: branch to checkout (default: main)
    - token: GitHub token for auth (optional)
    - callback: function to receive streaming output (optional)

  Returns {:ok, output} or {:error, reason}.
  """
  def clone_into_volume(volume_name, git_url, opts \\ []) do
    branch = Keyword.get(opts, :branch, "main")
    callback = Keyword.get(opts, :callback, fn _ -> :ok end)

    case create_volume(volume_name) do
      :ok ->
        Logger.info("[VolumeManager] Cloning #{git_url} (branch: #{branch}) into volume #{volume_name}")

        # Clone on the HOST using the host's git binary. Picks up SSH keys,
        # credential helpers, .gitconfig — whatever the user has configured.
        # No Docker container, no image pull needed.
        #
        # Use /tmp/colima (mounted into Colima VM by default) instead of
        # System.tmp_dir! (/var/folders/...) which isn't accessible to Docker.
        tmp_dir = Path.join("/tmp/colima", "bl-clone-#{:erlang.unique_integer([:positive])}")
        File.mkdir_p!(Path.dirname(tmp_dir))

        try do
          case host_git_clone(git_url, branch, tmp_dir, callback) do
            {:ok, _} ->
              case copy_to_volume(volume_name, tmp_dir, callback: callback) do
                {:ok, _} ->
                  Logger.info("[VolumeManager] Clone completed successfully")
                  {:ok, "cloned"}

                {:error, reason} ->
                  Logger.error("[VolumeManager] Copy to volume failed: #{reason}")
                  {:error, reason}
              end

            {:error, reason} ->
              Logger.error("[VolumeManager] Clone failed: #{reason}")
              {:error, reason}
          end
        after
          File.rm_rf(tmp_dir)
        end

      {:error, reason} ->
        {:error, "Failed to create volume: #{reason}"}
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

    auth_url = if token, do: inject_token(git_url, token), else: git_url

    # Clone directly in workspace container (already has git installed)
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
    # Run a quick check to see if /workspace has files
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
  Read a file from a volume. Uses running container if available, otherwise spins up temporary container.
  """
  def read_file(volume_name, path) do
    # Try to find a running workspace container for this volume
    case find_container_for_volume(volume_name) do
      {:ok, container} ->
        BoomLooper.Docker.exec_in(container, "cat /workspace/#{path}")

      :none ->
        # No running container, use temporary alpine
        case Docker.docker([
          "run", "--rm",
          "-v", "#{volume_name}:/workspace",
          "alpine", "cat", "/workspace/#{path}"
        ]) do
          {:ok, content} -> {:ok, content}
          {:error, _} -> {:error, :not_found}
        end
    end
  end

  @doc """
  Write a file to a volume. Uses running container if available, otherwise spins up temporary container.
  """
  def write_file(volume_name, path, content) do
    dir = Path.dirname(path)
    encoded = Base.encode64(content)

    case find_container_for_volume(volume_name) do
      {:ok, container} ->
        script = "mkdir -p /workspace/#{dir} && echo '#{encoded}' | base64 -d > /workspace/#{path}"
        case BoomLooper.Docker.exec_in(container, script) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end

      :none ->
        # No running container, use temporary alpine
        script = "mkdir -p /workspace/#{dir} && echo \"$FILE_CONTENT\" | base64 -d > /workspace/#{path}"

        case Docker.docker([
          "run", "--rm",
          "-e", "FILE_CONTENT=#{encoded}",
          "-v", "#{volume_name}:/workspace",
          "alpine", "sh", "-c", script
        ]) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # Find a running workspace container that has this volume mounted
  defp find_container_for_volume(volume_name) do
    # Volume names are like bl-{workspace_id}-code
    case Regex.run(~r/^bl-([a-f0-9]+)-code$/, volume_name) do
      [_, workspace_id] ->
        container = "bl-#{workspace_id}-workspace-1"
        if BoomLooper.Docker.container_running?(container) do
          {:ok, container}
        else
          :none
        end

      _ ->
        :none
    end
  end

  @doc """
  Copy a local directory into a volume.
  Used to migrate path-based workspaces to volume-based.
  The local directory becomes the initial content of the volume.
  """
  def copy_to_volume(volume_name, source_path, opts \\ []) do
    callback = Keyword.get(opts, :callback, fn _ -> :ok end)

    case create_volume(volume_name) do
      :ok ->
        # Use rsync in a container that mounts both source and target
        # -a = archive mode (preserves permissions, timestamps, etc.)
        # --delete = remove files in dest that aren't in source
        # Exclude common build artifacts and dependencies
        rsync_args = [
          "run", "--rm",
          "-v", "#{source_path}:/source:ro",
          "-v", "#{volume_name}:/workspace",
          "alpine", "sh", "-c",
          "apk add --no-cache rsync >/dev/null 2>&1 && " <>
          "rsync -a --delete " <>
          "--exclude node_modules " <>
          "--exclude .git/objects " <>
          "--exclude deps " <>
          "--exclude _build " <>
          "--exclude target " <>
          "--exclude vendor/bundle " <>
          "/source/ /workspace/"
        ]

        Logger.info("[VolumeManager] Copying #{source_path} to volume #{volume_name}")

        case Docker.stream(rsync_args, callback, timeout: @clone_timeout) do
          {:ok, output} ->
            Logger.info("[VolumeManager] Copy completed successfully")
            {:ok, output}

          {:error, output} ->
            Logger.error("[VolumeManager] Copy failed: #{output}")
            {:error, output}
        end

      {:error, reason} ->
        {:error, "Failed to create volume: #{reason}"}
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

  # --- Private ---

  # Clone a git repo on the host using the host's git binary. Picks up
  # SSH keys, credential helpers, .gitconfig — whatever the user has.
  defp host_git_clone(git_url, branch, dest, callback) do
    git_path = System.find_executable("git")

    unless git_path do
      {:error, "git not found on host PATH"}
    else
      port = Port.open(
        {:spawn_executable, git_path},
        [:binary, :exit_status, :stderr_to_stdout,
         {:args, ["clone", "--branch", branch, "--depth", "1", git_url, dest]}]
      )

      collect_clone_output(port, callback, "", @clone_timeout)
    end
  end

  defp collect_clone_output(port, callback, acc, timeout) do
    receive do
      {^port, {:data, data}} ->
        callback.(data)
        collect_clone_output(port, callback, acc <> data, timeout)

      {^port, {:exit_status, 0}} ->
        {:ok, acc}

      {^port, {:exit_status, _code}} ->
        {:error, acc}
    after
      timeout ->
        Port.close(port)
        {:error, acc <> "\n(timed out)"}
    end
  end

  defp inject_token(git_url, token) do
    # Convert git@github.com:owner/repo.git to https://token@github.com/owner/repo.git
    cond do
      String.starts_with?(git_url, "git@github.com:") ->
        path = String.replace(git_url, "git@github.com:", "")
        "https://#{token}@github.com/#{path}"

      String.starts_with?(git_url, "https://github.com/") ->
        String.replace(git_url, "https://github.com/", "https://#{token}@github.com/")

      true ->
        git_url
    end
  end

end
