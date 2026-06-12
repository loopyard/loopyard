defmodule Loopyard.Workspace.WorkContainer do
  @moduledoc """
  The **cheap, Loopyard-owned agent container** — the place an agent (and a
  human via the terminal) actually does work, *without* booting the project's
  dev/preview compose cluster.

  This is the heart of "working is the default state" (north-star D10). A
  workspace is a git branch in its own env; *most* of the time you just want to
  read/write code and run commands against the code volume — not stand up
  postgres, redis, and a dev server. The full compose cluster
  (`.loopyard/workspace/docker-compose.yml`) is the **preview env** and is
  opt-in (`Loopyard.Onboarding.start_preview/1`).

  The work container is:

    * **Stock** — built from `priv/workspace-base/Dockerfile` (alpine + git +
      gh + ssh + bash + curl + rsync). Loopyard owns it; the agent does not
      write it.
    * **Cheap** — `sleep infinity`, no build of the project image, no services.
      Boots in well under a second once the base image is cached.
    * **Code-mounted** — mounts the `loopyard-<ws>-code` volume at `/workspace`,
      so the agent sees the branch's code natively (identical macOS/Linux fs;
      no Mutagen, no host bind mount).
    * **Disposable** — `down/1` removes it; the code lives in the volume + git,
      so nothing is lost.

  Naming: `loopyard-<ws>-work`, distinct from the compose service container
  `loopyard-<ws>-workspace-1`. Both mount the same code volume, so an agent can
  exec into either; the work container is the one that's *always cheap to have*.
  """

  require Logger

  alias Loopyard.{Docker, VolumeManager}

  @image "loopyard-workspace-base:latest"
  @workdir "/workspace"

  @doc "Container name for a workspace's cheap work container."
  @spec container_name(String.t()) :: String.t()
  def container_name(workspace_id), do: "loopyard-#{workspace_id}-work"

  @doc "The stock base image tag the work container runs."
  @spec image() :: String.t()
  def image, do: @image

  @doc "Is the work container running?"
  @spec running?(String.t()) :: boolean()
  def running?(workspace_id), do: Docker.container_running?(container_name(workspace_id))

  @doc """
  Ensure the work container is up and mounting the workspace's code volume.

  Idempotent:

    * already running → `{:ok, name}`
    * exists but stopped → start it
    * absent → build the base image if missing, ensure the code volume, run it

  Returns `{:ok, container_name}` or `{:error, reason}`.
  """
  @spec ensure_up(String.t()) :: {:ok, String.t()} | {:error, term()}
  def ensure_up(workspace_id) do
    name = container_name(workspace_id)

    cond do
      Docker.container_running?(name) ->
        {:ok, name}

      Docker.container_exists?(name) ->
        # Stopped leftover (e.g. across a daemon restart) — start it back up.
        case Docker.docker(["start", name]) do
          {:ok, _} -> {:ok, name}
          {:error, _} -> recreate(workspace_id, name)
        end

      true ->
        recreate(workspace_id, name)
    end
  end

  @doc """
  Exec a shell command inside the work container, from `/workspace`.

  Brings the container up first if needed, so callers don't have to sequence
  `ensure_up` themselves. Returns `Docker.exec_in/3`'s `{:ok, output}` /
  `{:error, reason}`.
  """
  @spec exec(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def exec(workspace_id, command, opts \\ []) do
    with {:ok, name} <- ensure_up(workspace_id) do
      Docker.exec_in(name, command, Keyword.put_new(opts, :workdir, @workdir))
    end
  end

  @doc "Stop + remove the work container. The code volume is untouched."
  @spec down(String.t()) :: :ok
  def down(workspace_id) do
    name = container_name(workspace_id)
    _ = Docker.docker(["rm", "-f", name])
    :ok
  end

  @doc """
  Build the stock base image if it isn't present yet. Idempotent and safe to
  call on the hot path — skips the build when the image already exists.
  """
  @spec ensure_image() :: :ok | {:error, term()}
  def ensure_image do
    if image_present?() do
      :ok
    else
      context = Application.app_dir(:loopyard, "priv/workspace-base")
      Logger.info("Building stock workspace base image #{@image} from #{context}")

      case Docker.docker(["build", "-t", @image, context], timeout: 600_000) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # --- internals ---

  defp recreate(workspace_id, name) do
    volume = VolumeManager.code_volume_name(workspace_id)

    with :ok <- ensure_image(),
         :ok <- ensure_volume(volume),
         # Clear any stopped container of the same name before run.
         _ <- Docker.docker(["rm", "-f", name]),
         {:ok, _} <- run(name, volume) do
      {:ok, name}
    end
  end

  defp run(name, volume) do
    # Mount the branch's code at /workspace AND the shared workstation $HOME
    # volume at /root — so the agent inherits the logins/tools the user set up
    # in the Workstation console (gh/claude/fly/mise), exactly like every other
    # agent. Single-user MVP: one home volume (docker auto-creates by name if the
    # console hasn't been opened yet; the console reuses the same name).
    Docker.docker([
      "run",
      "-d",
      "--name",
      name,
      "--init",
      "-v",
      "#{volume}:#{@workdir}",
      "-v",
      "#{Loopyard.Workstation.Container.home_volume()}:/root",
      "-w",
      @workdir,
      @image,
      "sleep",
      "infinity"
    ])
  end

  defp ensure_volume(volume) do
    if VolumeManager.volume_exists?(volume), do: :ok, else: VolumeManager.create_volume(volume)
  end

  defp image_present? do
    case Docker.docker(["image", "inspect", @image], retry: false) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end
end
