defmodule Loopyard.CanonicalStore do
  @moduledoc """
  Durable persistence for canonical-backed projects (#19).

  A JSON map at `<LOOPYARD_HOME>/canonical_projects.json` of
  `project_id => %{name, remote, workspaces}` — minimal metadata, all
  strings/bools (no atoms/DateTimes to round-trip). The Docker volumes are
  durable on their own; this records just enough to re-register the projects +
  workspaces in ETS on boot (`Loopyard.Onboarding.restore/0`).
  """
  alias Loopyard.Workspace

  @spec path() :: String.t()
  def path, do: Path.join(Workspace.home_dir(), "canonical_projects.json")

  @spec load() :: map()
  def load do
    case File.read(path()) do
      {:error, :enoent} ->
        %{}

      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, %{} = map} ->
            map

          # File exists but is corrupt. Raise instead of returning %{} so the
          # boot restore (wrapped in safe_restore) leaves the file intact for
          # recovery rather than letting a later empty write() clobber it.
          _ ->
            raise "canonical_projects.json is corrupt: #{path()}"
        end

      {:error, reason} ->
        raise "canonical_projects.json could not be read (#{inspect(reason)}): #{path()}"
    end
  end

  @spec write(map()) :: :ok
  def write(%{} = map) do
    File.mkdir_p!(Path.dirname(path()))
    tmp = path() <> ".tmp"
    File.write!(tmp, Jason.encode!(map, pretty: true))
    File.rename!(tmp, path())
    :ok
  end

  @spec put(String.t(), map()) :: :ok
  def put(project_id, entry), do: load() |> Map.put(project_id, entry) |> write()

  @spec delete(String.t()) :: :ok
  def delete(project_id), do: load() |> Map.delete(project_id) |> write()
end
