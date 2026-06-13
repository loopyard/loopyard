defmodule Loopyard.Workstation.Container do
  @moduledoc """
  The long-lived **workstation container** — a shell on *your machine*, separate
  from any project. It boots the workstation image with the workstation `$HOME`
  volume mounted at `/root`, so logins you do here (`gh auth login`,
  `claude login`, `fly auth login`) and versions you install (`mise use …`) land
  in the `$HOME` volume and **persist** — and every agent that mounts the same
  `$HOME` inherits them.

  This is the "console" half of a workstation (the Workstation page renders a
  terminal into it). Single-user MVP: one container + one home volume; per-user
  is a later refinement keyed by the profile id.

  Tools live in the *image* (system paths like `/usr/local/bin`), so mounting
  the volume at `/root` (`$HOME`) holds only mutable state and never shadows the
  tools — the deliberate image/`$HOME` split (plans/workstations.md).
  """
  require Logger

  alias Loopyard.{Docker, VolumeManager, Workstation}

  @name "loopyard-workstation"
  @home_volume "loopyard-workstation-home"
  # The harness/console run as root, so $HOME is /root.
  @home "/root"

  @doc "The workstation container name (what the terminal channel attaches to)."
  @spec name() :: String.t()
  def name, do: @name

  @doc "The per-user `$HOME` volume name (single-user MVP)."
  @spec home_volume() :: String.t()
  def home_volume, do: @home_volume

  @spec running?() :: boolean()
  def running?, do: Docker.container_running?(@name)

  @doc """
  Ensure the workstation container is up, mounting the `$HOME` volume. Idempotent
  (running → ok; stopped → start; absent → build image if needed, ensure volume,
  run). Returns `{:ok, name}` or `{:error, reason}`.
  """
  @spec ensure_up() :: {:ok, String.t()} | {:error, term()}
  def ensure_up do
    cond do
      Docker.container_running?(@name) ->
        {:ok, @name}

      Docker.container_exists?(@name) ->
        case Docker.docker(["start", @name]) do
          {:ok, _} -> {:ok, @name}
          {:error, _} -> recreate()
        end

      true ->
        recreate()
    end
  end

  @doc "Stop + remove the workstation container. The `$HOME` volume is untouched."
  @spec down() :: :ok
  def down do
    _ = Docker.docker(["rm", "-f", @name])
    :ok
  end

  # --- internals ---

  defp recreate do
    with :ok <- Workstation.Image.ensure_built(),
         :ok <- ensure_volume(),
         _ <- Docker.docker(["rm", "-f", @name]),
         {:ok, _} <- run() do
      {:ok, @name}
    end
  end

  defp run do
    Docker.docker(
      [
        "run",
        "-d",
        "--name",
        @name,
        "--init",
        "-v",
        "#{@home_volume}:#{@home}",
        "-w",
        @home
      ] ++
        Workstation.Env.env_args() ++
        [
          Workstation.Image.tag(),
          "sleep",
          "infinity"
        ]
    )
  end

  defp ensure_volume do
    if VolumeManager.volume_exists?(@home_volume),
      do: :ok,
      else: VolumeManager.create_volume(@home_volume)
  end
end
