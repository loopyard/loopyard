defmodule Loopyard.VolumeIO do
  @moduledoc """
  File I/O operations on Docker volumes.

  Reads and writes files inside volumes, using running workspace containers
  when available, or spinning up temporary Alpine containers otherwise.
  """

  alias Loopyard.Docker

  @doc """
  Read a file from a volume. Uses running container if available, otherwise spins up temporary container.
  """
  def read_file(volume_name, path) do
    with {:ok, abs} <- validate_path(path) do
      # Try to find a running workspace container for this volume
      case find_container_for_volume(volume_name) do
        {:ok, container} ->
          Loopyard.Docker.exec_in(container, "cat #{shq(abs)}")

        :none ->
          # No running container, use temporary alpine. `abs` is a normalized,
          # /workspace-confined path; passed as a discrete arg (never a shell
          # word) so metacharacters in a filename can't inject.
          case Docker.docker([
                 "run",
                 "--rm",
                 "-v",
                 "#{volume_name}:/workspace",
                 "alpine",
                 "cat",
                 abs
               ]) do
            {:ok, content} -> {:ok, content}
            {:error, _} -> {:error, :not_found}
          end
      end
    end
  end

  @doc """
  Write a file to a volume. Uses running container if available, otherwise spins up temporary container.
  """
  def write_file(volume_name, path, content) do
    with {:ok, abs} <- validate_path(path) do
      dir = Path.dirname(abs)
      encoded = Base.encode64(content)

      case find_container_for_volume(volume_name) do
        {:ok, container} ->
          script =
            "mkdir -p #{shq(dir)} && echo '#{encoded}' | base64 -d > #{shq(abs)}"

          case Loopyard.Docker.exec_in(container, script) do
            {:ok, _} -> :ok
            {:error, reason} -> {:error, reason}
          end

        :none ->
          # No running container, use temporary alpine
          script =
            "mkdir -p #{shq(dir)} && echo \"$FILE_CONTENT\" | base64 -d > #{shq(abs)}"

          case Docker.docker([
                 "run",
                 "--rm",
                 "-e",
                 "FILE_CONTENT=#{encoded}",
                 "-v",
                 "#{volume_name}:/workspace",
                 "alpine",
                 "sh",
                 "-c",
                 script
               ]) do
            {:ok, _} -> :ok
            {:error, reason} -> {:error, reason}
          end
      end
    end
  end

  @doc """
  Copy a HOST file into a volume at `dest` (an absolute `/workspace/...` path
  or one relative to it) — the write path for binary/large content.

  `write_file/3` shells the bytes through a base64 argument, which caps out at
  the kernel's per-argument limit (~128KB) — a screenshot won't fit. `docker cp`
  streams the file over the API from the docker CLI on the host, so it has no
  size ceiling and works under Colima (no bind mount involved). Copies into
  the running workspace container when there is one, else through a throwaway
  container that mounts the volume.
  """
  @spec copy_in(String.t(), Path.t(), String.t()) :: :ok | {:error, term()}
  def copy_in(volume_name, host_path, dest) do
    with {:ok, abs} <- validate_path(dest),
         true <- File.regular?(host_path) || {:error, :enoent} do
      dir = Path.dirname(abs)

      case find_container_for_volume(volume_name) do
        {:ok, container} ->
          with {:ok, _} <- Loopyard.Docker.exec_in(container, "mkdir -p #{shq(dir)}"),
               {:ok, _} <- Docker.docker(["cp", host_path, "#{container}:#{abs}"]) do
            :ok
          end

        :none ->
          # No running container: `docker cp` needs one, so make a throwaway
          # on the volume, copy into it, and remove it.
          name = "#{Docker.prefix()}cp-#{System.unique_integer([:positive])}"

          with {:ok, _} <-
                 Docker.docker(~w(run --rm -v #{volume_name}:/workspace alpine mkdir -p) ++ [dir]),
               {:ok, _} <-
                 Docker.docker(~w(create --name #{name} -v #{volume_name}:/workspace alpine)) do
            result = Docker.docker(["cp", host_path, "#{name}:#{abs}"])
            Docker.docker(["rm", "-f", name])

            case result do
              {:ok, _} -> :ok
              {:error, reason} -> {:error, reason}
            end
          end
      end
    end
  end

  @doc """
  Seed a volume from a host directory. Uses rsync WITHOUT `--delete` so
  re-running on a partially-populated volume is safe (missing files are
  added, existing files are updated by mtime, no extra files are removed).

  After a successful seed, writes a `.loopyard/.seeded` sentinel into
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
      "run",
      "--rm",
      "-v",
      "#{source_path}:/source:ro",
      "-v",
      "#{volume_name}:/workspace",
      "alpine",
      "sh",
      "-c",
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
        "mkdir -p /workspace/.loopyard && " <>
        "date -u +%Y-%m-%dT%H:%M:%SZ > /workspace/.loopyard/.seeded"
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
  Returns true if the volume has been seeded (has the `.loopyard/.seeded`
  sentinel). Used by `Workspace.Setup` to skip a re-seed on retry / restart
  recovery when the volume is already populated.
  """
  def seeded?(volume_name) do
    case Docker.docker([
           "run",
           "--rm",
           "-v",
           "#{volume_name}:/workspace",
           "alpine",
           "sh",
           "-c",
           "test -f /workspace/.loopyard/.seeded && echo yes || echo no"
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

    case Loopyard.VolumeManager.create_volume(volume_name) do
      :ok ->
        # Use rsync in a container that mounts both source and target
        rsync_args = [
          "run",
          "--rm",
          "-v",
          "#{source_path}:/source:ro",
          "-v",
          "#{volume_name}:/workspace",
          "alpine",
          "sh",
          "-c",
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
    # This one shells out on its own (System.shell, not Docker.docker/2), so it
    # must honour the daemon gate itself: with Docker off (the default test
    # suite) it used to spawn the real CLI on EVERY agent boot — ~230 ms a
    # test, and `docker run -v <name>` auto-creates the volume, so each test
    # workspace leaked one. Nothing to mirror is `:ok`.
    if Docker.daemon_available?() do
      do_mirror_dir(volume_name, src_rel, dest_abs)
    else
      :ok
    end
  end

  defp do_mirror_dir(volume_name, src_rel, dest_abs) do
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

  # Normalize `path` against /workspace and reject anything that escapes it
  # (traversal, absolute paths outside the volume) or carries a null byte.
  # Returns {:ok, absolute_path} confined to /workspace. Every command below
  # either passes this as a discrete exec arg or shell-quotes it, so a
  # filename containing spaces or shell metacharacters is handled literally.
  defp validate_path(path) when is_binary(path) do
    if String.contains?(path, <<0>>) do
      {:error, :invalid_path}
    else
      abs = Path.expand(path, "/workspace")

      if abs == "/workspace" or String.starts_with?(abs, "/workspace/") do
        {:ok, abs}
      else
        {:error, :invalid_path}
      end
    end
  end

  defp validate_path(_), do: {:error, :invalid_path}

  # POSIX single-quote escape: wrap in '…' and replace embedded ' with '"'"'.
  defp shq(s) when is_binary(s), do: "'" <> String.replace(s, "'", "'\"'\"'") <> "'"

  # Find a running container that has this volume mounted: the always-on
  # work container first (`<prefix><ws>-work`, the agent's box), then a
  # compose `workspace` service if the project defines one. Volume names are
  # `<prefix><workspace_id>-code`.
  defp find_container_for_volume(volume_name) do
    prefix = Regex.escape(Loopyard.Docker.prefix())

    case Regex.run(~r/^#{prefix}([a-f0-9]+)-code$/, volume_name) do
      [_, workspace_id] ->
        [
          Loopyard.Workspace.WorkContainer.container_name(workspace_id),
          "#{Loopyard.Docker.prefix()}#{workspace_id}-workspace-1"
        ]
        |> Enum.find(&Loopyard.Docker.container_running?/1)
        |> case do
          nil -> :none
          container -> {:ok, container}
        end

      _ ->
        :none
    end
  end
end
