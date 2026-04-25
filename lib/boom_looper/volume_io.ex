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
  Seed a volume from a host directory. Uses rsync WITHOUT `--delete` so
  re-running on a partially-populated volume is safe (missing files are
  added, existing files are updated by mtime, no extra files are removed).

  After a successful seed, writes a `.boomlooper/.seeded` sentinel into
  the volume. Callers can use `seeded?/1` to skip a re-seed when the
  volume is already populated. The sentinel is necessary because
  `volume_has_code?/1` checks for `.git/objects`, which is excluded from
  the rsync, so it would always report "no code" for Local workspaces.

  Used by `Workspace.Setup` for the `:seeding` saga step.
  """
  def seed_from_host(volume_name, source_path, opts \\ []) do
    callback = Keyword.get(opts, :callback, fn _ -> :ok end)
    seed_timeout = Keyword.get(opts, :timeout, 600_000)

    rsync_args = [
      "run", "--rm",
      "-v", "#{source_path}:/source:ro",
      "-v", "#{volume_name}:/workspace",
      "alpine", "sh", "-c",
      "apk add --no-cache rsync >/dev/null 2>&1 && " <>
      "rsync -a --info=progress2,name1 " <>
      "--exclude .git/objects " <>
      "--exclude .git/lfs " <>
      "--exclude node_modules " <>
      "--exclude deps " <>
      "--exclude _build " <>
      "--exclude target " <>
      "--exclude vendor/bundle " <>
      "--exclude .next " <>
      "--exclude .venv " <>
      "--exclude __pycache__ " <>
      "/source/ /workspace/ && " <>
      "mkdir -p /workspace/.boomlooper && " <>
      "date -u +%Y-%m-%dT%H:%M:%SZ > /workspace/.boomlooper/.seeded"
    ]

    require Logger
    Logger.info("[VolumeIO] Seeding #{source_path} into volume #{volume_name}")

    case Docker.stream(rsync_args, callback, timeout: seed_timeout) do
      {:ok, output} ->
        Logger.info("[VolumeIO] Seed completed successfully")
        {:ok, output}

      {:error, output} ->
        Logger.error("[VolumeIO] Seed failed: #{inspect(output)}")
        {:error, output}
    end
  end

  @doc """
  Returns true if the volume has been seeded (has the `.boomlooper/.seeded`
  sentinel). Used by `Workspace.Setup` to skip a re-seed on retry / restart
  recovery when the volume is already populated.
  """
  def seeded?(volume_name) do
    case Docker.docker([
      "run", "--rm",
      "-v", "#{volume_name}:/workspace",
      "alpine", "sh", "-c",
      "test -f /workspace/.boomlooper/.seeded && echo yes || echo no"
    ]) do
      {:ok, output} -> String.trim(output) == "yes"
      {:error, _} -> false
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

  @doc """
  Mirror a directory from a volume to a local host path. Uses tar piped
  through docker so one round-trip covers the whole tree. Missing source
  directory is not an error — the destination just stays untouched.

  Returns `:ok` or `{:error, reason}`.
  """
  def mirror_dir(volume_name, src_rel, dest_abs)
      when is_binary(volume_name) and is_binary(src_rel) and is_binary(dest_abs) do
    File.mkdir_p!(dest_abs)

    # Use a shell pipeline to tar from the volume and untar on the host.
    # `|| true` swallows the "no such directory" case so we exit 0 when
    # the volume simply has no `.claude/`.
    cmd =
      "docker run --rm -v #{volume_name}:/workspace alpine " <>
        "sh -c 'cd /workspace && tar cf - #{src_rel} 2>/dev/null || true' " <>
        "| tar xf - -C #{dest_abs} 2>/dev/null || true"

    case System.shell(cmd, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, code} -> {:error, "mirror_dir exited #{code}: #{out}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
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
