defmodule BoomLooper.VolumeManager do
  @moduledoc """
  Manages Docker volumes for workspaces.

  Each workspace gets a named volume for code storage. Code is cloned from git
  into the volume, eliminating bind mount issues (Unix sockets, file watchers,
  platform binaries).
  """

  require Logger

  @clone_image "alpine/git:latest"
  @clone_timeout 300_000  # 5 minutes

  # --- Volume Operations ---

  @doc """
  Create a named Docker volume.
  Returns :ok if created or already exists.
  """
  def create_volume(volume_name) do
    case docker(["volume", "create", volume_name]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Delete a named Docker volume.
  """
  def delete_volume(volume_name) do
    case docker(["volume", "rm", "-f", volume_name]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Check if a volume exists.
  """
  def volume_exists?(volume_name) do
    case docker(["volume", "inspect", volume_name]) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  @doc """
  Delete all code-* and cache-* volumes not associated with an active workspace.
  Returns {:ok, deleted_count} or {:error, reason}.
  """
  def prune_orphaned_volumes do
    # Find active workspace IDs
    active_ids = BoomLooper.ProjectRegistry.list_projects()
    |> Enum.flat_map(fn p -> BoomLooper.ProjectRegistry.list_workspaces(p.id) end)
    |> Enum.map(fn ws -> BoomLooper.Workspace.workspace_id(ws.path) end)
    |> MapSet.new()

    # List all Docker volumes
    case docker(["volume", "ls", "--format", "{{.Name}}"]) do
      {:ok, output} ->
        volumes = output |> String.trim() |> String.split("\n", trim: true)

        orphans = Enum.filter(volumes, fn name ->
          case Regex.run(~r/^(?:code|cache|bl-.*_cache)-([a-f0-9]{4})$/, name) do
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
          match?({:ok, _}, docker(["volume", "rm", "-f", name]))
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
    token = Keyword.get(opts, :token)
    callback = Keyword.get(opts, :callback, fn _ -> :ok end)

    # Create volume first
    case create_volume(volume_name) do
      :ok ->
        # Build clone command
        auth_url = if token, do: inject_token(git_url, token), else: git_url

        clone_args = [
          "run", "--rm",
          "-v", "#{volume_name}:/workspace",
          @clone_image,
          "clone", "--branch", branch, "--depth", "1", auth_url, "/workspace"
        ]

        Logger.info("[VolumeManager] Cloning #{git_url} (branch: #{branch}) into volume #{volume_name}")

        case stream_docker(clone_args, callback) do
          {:ok, output} ->
            Logger.info("[VolumeManager] Clone completed successfully")
            {:ok, output}

          {:error, output} ->
            Logger.error("[VolumeManager] Clone failed: #{output}")
            {:error, output}
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

    case docker(["exec", container, "sh", "-c", clone_cmd], timeout: @clone_timeout) do
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

    case docker(["exec", container, "git", "-C", "/workspace", "pull"]) do
      {:ok, output} -> {:ok, output}
      {:error, reason} -> {:error, reason}
    end
  end


  @doc """
  Check if a volume has code (not empty).
  """
  def volume_has_code?(volume_name) do
    # Run a quick check to see if /workspace has files
    case docker([
      "run", "--rm",
      "-v", "#{volume_name}:/workspace",
      "alpine", "sh", "-c", "test -d /workspace/.git && echo yes || echo no"
    ]) do
      {:ok, output} -> String.trim(output) == "yes"
      {:error, _} -> false
    end
  end

  @doc """
  Read a file from a volume without a running container.
  """
  def read_file(volume_name, path) do
    case docker([
      "run", "--rm",
      "-v", "#{volume_name}:/workspace",
      "alpine", "cat", "/workspace/#{path}"
    ]) do
      {:ok, content} -> {:ok, content}
      {:error, _} -> {:error, :not_found}
    end
  end

  @doc """
  Write a file to a volume without a running container.
  """
  def write_file(volume_name, path, content) do
    dir = Path.dirname(path)
    encoded = Base.encode64(content)

    script = "mkdir -p /workspace/#{dir} && echo \"$FILE_CONTENT\" | base64 -d > /workspace/#{path}"

    case docker([
      "run", "--rm",
      "-e", "FILE_CONTENT=#{encoded}",
      "-v", "#{volume_name}:/workspace",
      "alpine", "sh", "-c", script
    ]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
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

        case stream_docker(rsync_args, callback) do
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
    case docker([
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

  defp docker(args, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)

    task = Task.async(fn ->
      System.cmd("docker", args, stderr_to_stdout: true)
    end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, {output, 0}} -> {:ok, output}
      {:ok, {output, _}} -> {:error, output}
      nil -> {:error, "docker command timed out"}
    end
  end

  defp stream_docker(args, callback) do
    docker_path = System.find_executable("docker")

    unless docker_path do
      {:error, "docker not found"}
    else
      port = Port.open(
        {:spawn_executable, docker_path},
        [:binary, :exit_status, :stderr_to_stdout, {:args, args}]
      )

      collect_streaming_output(port, callback, "", @clone_timeout)
    end
  end

  defp collect_streaming_output(port, callback, acc, timeout) do
    receive do
      {^port, {:data, data}} ->
        callback.(data)
        collect_streaming_output(port, callback, acc <> data, timeout)

      {^port, {:exit_status, 0}} ->
        {:ok, acc}

      {^port, {:exit_status, _}} ->
        {:error, acc}
    after
      timeout ->
        Port.close(port)
        {:error, acc <> "\n(timed out)"}
    end
  end
end
