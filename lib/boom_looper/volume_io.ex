defmodule BoomLooper.VolumeIO do
  @moduledoc """
  File I/O operations on Docker volumes.

  Reads and writes files inside volumes, using running workspace containers
  when available, or spinning up temporary Alpine containers otherwise.
  """

  alias BoomLooper.Docker

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

  @doc """
  Copy a local directory into a volume.
  Used to migrate path-based workspaces to volume-based.
  The local directory becomes the initial content of the volume.
  """
  def copy_to_volume(volume_name, source_path, opts \\ []) do
    callback = Keyword.get(opts, :callback, fn _ -> :ok end)
    clone_timeout = 300_000

    case BoomLooper.VolumeManager.create_volume(volume_name) do
      :ok ->
        # Use rsync in a container that mounts both source and target
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

        require Logger
        Logger.info("[VolumeIO] Copying #{source_path} to volume #{volume_name}")

        case Docker.stream(rsync_args, callback, timeout: clone_timeout) do
          {:ok, output} ->
            Logger.info("[VolumeIO] Copy completed successfully")
            {:ok, output}

          {:error, output} ->
            Logger.error("[VolumeIO] Copy failed: #{output}")
            {:error, output}
        end

      {:error, reason} ->
        {:error, "Failed to create volume: #{reason}"}
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
end
