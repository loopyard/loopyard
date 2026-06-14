defmodule Loopyard.Workstation.Image do
  @moduledoc """
  A **workstation's** base image — the Docker image its agents are stamped from.
  Keyed by workstation id (identity); `id` is **required** — there is no implicit
  "current" default, so a headless caller can never silently inherit the UI's
  current identity. The *UI* resolves `Loopyard.Workstation.current/0` at its
  boundary and passes the id down. The Dockerfile lives in the workstation's dir
  (`<LOOPYARD_HOME>/workstations/<id>/Dockerfile`), seeded from the stock base in
  `priv/workspace-base/`. Editable + rebuildable from the Workstation page.
  """
  alias Loopyard.{Docker, Workstation}

  def tag(id), do: Workstation.image_tag(id)
  def dir(id), do: Workstation.dir(id)
  def dockerfile_path(id), do: Path.join(dir(id), "Dockerfile")

  @doc "Read the workstation's Dockerfile, seeding it from the stock base on first use."
  @spec read_dockerfile(String.t()) :: {:ok, String.t()} | {:error, term()}
  def read_dockerfile(id) do
    ensure_seeded(id)
    File.read(dockerfile_path(id))
  end

  @doc "Overwrite the workstation's Dockerfile."
  @spec write_dockerfile(String.t(), String.t()) :: :ok | {:error, term()}
  def write_dockerfile(contents, id) when is_binary(contents) do
    File.mkdir_p!(dir(id))
    File.write(dockerfile_path(id), contents)
  end

  @doc "Rebuild the workstation image, streaming `docker build` output to `callback`."
  @spec build((String.t() -> any()), String.t()) :: :ok | {:error, term()}
  def build(callback, id) when is_function(callback, 1) do
    ensure_seeded(id)
    Docker.stream(["build", "--progress=plain", "-t", tag(id), dir(id)], callback, timeout: 1_800_000)
  end

  @doc "Build the workstation image if it isn't present yet (non-streaming, hot path)."
  @spec ensure_built(String.t()) :: :ok | {:error, term()}
  def ensure_built(id) do
    case Docker.docker(["image", "inspect", tag(id)], retry: false) do
      {:ok, _} ->
        :ok

      _ ->
        ensure_seeded(id)

        case Docker.docker(["build", "-t", tag(id), dir(id)], timeout: 1_800_000) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc "Status of the built image: `%{exists: bool, size: string|nil, created: string|nil}`."
  @spec status(String.t()) :: %{exists: boolean(), size: String.t() | nil, created: String.t() | nil}
  def status(id) do
    case Docker.docker(["image", "inspect", tag(id), "--format", "{{.Size}}|{{.Created}}"],
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

  defp ensure_seeded(id) do
    unless File.exists?(dockerfile_path(id)) do
      File.mkdir_p!(dir(id))
      stock = Application.app_dir(:loopyard, "priv/workspace-base/Dockerfile")
      File.cp!(stock, dockerfile_path(id))
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
