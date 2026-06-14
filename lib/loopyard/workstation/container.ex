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

  @doc """
  Run a shell command inside the workstation container (bringing it up first).
  Used for one-click token imports (`gh auth token`, …). Returns
  `Docker.exec_in/3`'s `{:ok, output} | {:error, reason}`.
  """
  @spec exec(String.t()) :: {:ok, String.t()} | {:error, term()}
  def exec(command) do
    with {:ok, name} <- ensure_up() do
      Docker.exec_in(name, command)
    end
  end

  @doc """
  Write a file into the workstation `$HOME` volume at `rel_path` (relative to
  `/root`). Creates parent dirs. Used to transfer credential files from your Mac
  (`~/.codex/auth.json`, `~/.config/gh/hosts.yml`, …) — they land in the shared
  `$HOME` volume, so every agent inherits them *live* (no restart needed).

  `rel_path` is validated: relative, no `..`, no NUL. Returns `:ok | {:error, _}`.
  """
  @spec write_file(String.t(), binary()) :: :ok | {:error, term()}
  def write_file(rel_path, content) when is_binary(rel_path) and is_binary(content) do
    with :ok <- validate_rel_path(rel_path),
         {:ok, name} <- ensure_up() do
      full = "#{@home}/#{rel_path}"
      dir = Path.dirname(full)
      b64 = Base.encode64(content)
      cmd = "mkdir -p '#{dir}' && printf '%s' '#{b64}' | base64 -d > '#{full}' && chmod 600 '#{full}'"

      case Docker.exec_in(name, cmd) do
        {:ok, _} -> :ok
        err -> err
      end
    end
  end

  defp validate_rel_path(p) do
    cond do
      p == "" -> {:error, :empty_path}
      String.starts_with?(p, "/") -> {:error, :absolute_path}
      String.contains?(p, "..") -> {:error, :path_traversal}
      String.contains?(p, "\0") -> {:error, :invalid_path}
      not Regex.match?(~r|^[A-Za-z0-9._/\-]+$|, p) -> {:error, :invalid_path}
      true -> :ok
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
