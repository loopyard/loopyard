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
    with {:ok, json} <- File.read(path()),
         {:ok, %{} = map} <- Jason.decode(json) do
      map
    else
      _ -> %{}
    end
  end

  @spec write(map()) :: :ok
  def write(%{} = map) do
    File.mkdir_p!(Path.dirname(path()))
    File.write!(path(), Jason.encode!(map, pretty: true))
    :ok
  end

  @spec put(String.t(), map()) :: :ok
  def put(project_id, entry), do: load() |> Map.put(project_id, entry) |> write()

  @spec delete(String.t()) :: :ok
  def delete(project_id), do: load() |> Map.delete(project_id) |> write()
end
