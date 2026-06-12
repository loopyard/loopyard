defmodule Loopyard.Workstation.Image do
  @moduledoc """
  The user's **workstation** base image — the Docker image every agent is
  stamped from (`Loopyard.Workspace.WorkContainer` runs containers from this
  tag). The Dockerfile lives in user data
  (`<LOOPYARD_HOME>/workstation/Dockerfile`), **seeded once** from the stock base
  shipped in `priv/workspace-base/`. From there it's the user's to edit and
  rebuild — from the Workstation page, which works from a phone.

  This is the "image" half of a workstation (the `$HOME` volume is the other
  half — see plans/workstations.md). Tools/system packages go here; logins and
  dotfiles live in `$HOME`.
  """
  alias Loopyard.{Docker, Workspace}

  # Same tag WorkContainer boots from — rebuilding here updates what agents use.
  @tag "loopyard-workspace-base:latest"

  def tag, do: @tag

  def dir, do: Path.join(Workspace.home_dir(), "workstation")
  def dockerfile_path, do: Path.join(dir(), "Dockerfile")

  @doc "Read the workstation Dockerfile, seeding it from the stock base on first use."
  @spec read_dockerfile() :: {:ok, String.t()} | {:error, term()}
  def read_dockerfile do
    ensure_seeded()
    File.read(dockerfile_path())
  end

  @doc "Overwrite the workstation Dockerfile."
  @spec write_dockerfile(String.t()) :: :ok | {:error, term()}
  def write_dockerfile(contents) when is_binary(contents) do
    File.mkdir_p!(dir())
    File.write(dockerfile_path(), contents)
  end

  @doc """
  Rebuild the workstation image, streaming `docker build` output line-by-line to
  `callback`. Writes nothing — call `write_dockerfile/1` first. Returns
  `:ok | {:error, reason}` when the build finishes.
  """
  @spec build((String.t() -> any())) :: :ok | {:error, term()}
  def build(callback) when is_function(callback, 1) do
    ensure_seeded()
    # `--progress=plain` gives readable, non-TTY line output to stream.
    Docker.stream(
      ["build", "--progress=plain", "-t", @tag, dir()],
      callback,
      timeout: 1_800_000
    )
  end

  @doc "Build the workstation image if it isn't present yet (non-streaming, for the hot path)."
  @spec ensure_built() :: :ok | {:error, term()}
  def ensure_built do
    case Docker.docker(["image", "inspect", @tag], retry: false) do
      {:ok, _} ->
        :ok

      _ ->
        ensure_seeded()

        case Docker.docker(["build", "-t", @tag, dir()], timeout: 1_800_000) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc "Status of the built image: `%{exists: bool, size: string|nil, created: string|nil}`."
  @spec status() :: %{exists: boolean(), size: String.t() | nil, created: String.t() | nil}
  def status do
    case Docker.docker(["image", "inspect", @tag, "--format", "{{.Size}}|{{.Created}}"],
           retry: false
         ) do
      {:ok, out} ->
        case String.split(String.trim(out), "|", parts: 2) do
          [size, created] -> %{exists: true, size: human_size(size), created: created}
          _ -> %{exists: true, size: nil, created: nil}
        end

      _ ->
        %{exists: false, size: nil, created: nil}
    end
  end

  defp ensure_seeded do
    unless File.exists?(dockerfile_path()) do
      File.mkdir_p!(dir())
      stock = Application.app_dir(:loopyard, "priv/workspace-base/Dockerfile")
      File.cp!(stock, dockerfile_path())
    end

    :ok
  end

  defp human_size(bytes_str) do
    case Integer.parse(String.trim(bytes_str)) do
      {b, _} when b >= 1_000_000_000 -> "#{Float.round(b / 1_000_000_000, 2)} GB"
      {b, _} -> "#{Float.round(b / 1_000_000, 0)} MB"
      _ -> nil
    end
  end
end
