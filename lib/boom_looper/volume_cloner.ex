defmodule BoomLooper.VolumeCloner do
  @moduledoc """
  Git clone operations into Docker volumes.

  Clones repositories on the host using the host's git binary (picks up SSH keys,
  credential helpers, .gitconfig), then copies the result into a Docker volume.
  """

  require Logger

  @clone_timeout 300_000  # 5 minutes

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

    case BoomLooper.VolumeManager.create_volume(volume_name) do
      :ok ->
        Logger.info("[VolumeCloner] Cloning #{git_url} (branch: #{branch}) into volume #{volume_name}")

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
              case BoomLooper.VolumeIO.copy_to_volume(volume_name, tmp_dir, callback: callback) do
                {:ok, _} ->
                  Logger.info("[VolumeCloner] Clone completed successfully")
                  {:ok, "cloned"}

                {:error, reason} ->
                  Logger.error("[VolumeCloner] Copy to volume failed: #{reason}")
                  {:error, reason}
              end

            {:error, reason} ->
              Logger.error("[VolumeCloner] Clone failed: #{reason}")
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
  Inject a GitHub token into a git URL for authentication.
  """
  def inject_token(git_url, token) do
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

  # --- Private ---

  # Clone a git repo on the host using the host's git binary.
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
end
