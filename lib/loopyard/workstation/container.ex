defmodule Loopyard.Workstation.Container do
  @moduledoc """
  The long-lived **workstation container** for an identity — a shell on *that
  person's machine*. Boots the workstation's image with its `$HOME` volume
  mounted at `/root`, so logins (`gh auth login`, …) and installs land in the
  volume and **persist**, and every agent on that identity inherits them.

  Keyed by workstation id; `id` is **required** — no implicit "current" default,
  so headless callers can't silently inherit the UI's current identity. The UI
  resolves `Loopyard.Workstation.current/0` at its boundary and passes the id
  down. Names come from `Loopyard.Workstation`.

  Tools live in the *image* (system paths), so mounting the volume at `/root`
  (`$HOME`) holds only mutable state and never shadows the tools.
  """
  require Logger

  alias Loopyard.{Docker, VolumeManager, Workstation}

  # The harness/console run as root, so $HOME is /root (in-container path).
  @home "/root"

  @doc "The workstation container name (what the terminal channel attaches to)."
  @spec name(String.t()) :: String.t()
  def name(id), do: Workstation.container_name(id)

  @doc "The identity's `$HOME` volume name."
  @spec home_volume(String.t()) :: String.t()
  def home_volume(id), do: Workstation.home_volume(id)

  @spec running?(String.t()) :: boolean()
  def running?(id), do: Docker.container_running?(name(id))

  @doc """
  Ensure the workstation container is up, mounting its `$HOME` volume. Idempotent
  (running → ok; stopped → start; absent → build image if needed, ensure volume,
  run). Returns `{:ok, name}` or `{:error, reason}`.
  """
  @spec ensure_up(String.t()) :: {:ok, String.t()} | {:error, term()}
  def ensure_up(id) do
    n = name(id)

    cond do
      Docker.container_running?(n) ->
        {:ok, n}

      Docker.container_exists?(n) ->
        case Docker.docker(["start", n]) do
          {:ok, _} -> {:ok, n}
          {:error, _} -> recreate(id)
        end

      true ->
        recreate(id)
    end
  end

  @doc "Run a shell command inside the workstation container (bringing it up first)."
  @spec exec(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def exec(command, id) do
    with {:ok, n} <- ensure_up(id) do
      Docker.exec_in(n, command)
    end
  end

  @doc """
  Write a file into the identity's `$HOME` volume at `rel_path` (relative to
  `/root`) — credential files transferred from your Mac land here, live, inherited
  by every agent on this identity. `rel_path` validated (relative, no `..`, no NUL).
  """
  @spec write_file(String.t(), binary(), String.t()) :: :ok | {:error, term()}
  def write_file(rel_path, content, id)
      when is_binary(rel_path) and is_binary(content) do
    with :ok <- validate_rel_path(rel_path),
         {:ok, n} <- ensure_up(id) do
      full = "#{@home}/#{rel_path}"
      dir = Path.dirname(full)
      b64 = Base.encode64(content)
      cmd = "mkdir -p '#{dir}' && printf '%s' '#{b64}' | base64 -d > '#{full}' && chmod 600 '#{full}'"

      case Docker.exec_in(n, cmd) do
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
  @spec down(String.t()) :: :ok
  def down(id) do
    _ = Docker.docker(["rm", "-f", name(id)])
    :ok
  end

  # --- internals ---

  defp recreate(id) do
    n = name(id)

    with :ok <- Workstation.Image.ensure_built(id),
         :ok <- ensure_volume(id),
         _ <- Docker.docker(["rm", "-f", n]),
         {:ok, _} <- run(id) do
      {:ok, n}
    end
  end

  defp run(id) do
    Docker.docker(
      [
        "run",
        "-d",
        "--name",
        name(id),
        "--init",
        "-v",
        "#{home_volume(id)}:#{@home}",
        "-w",
        @home
      ] ++
        Workstation.Env.env_args(id) ++
        [
          Workstation.Image.tag(id),
          "sleep",
          "infinity"
        ]
    )
  end

  defp ensure_volume(id) do
    v = home_volume(id)
    if VolumeManager.volume_exists?(v), do: :ok, else: VolumeManager.create_volume(v)
  end
end
