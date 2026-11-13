defmodule Loopyard.Test.DockerVolumeSweep do
  @moduledoc """
  The test suite removes the Docker volumes and containers it creates (issue #117).

  Only meaningful for a run with the daemon gate OPEN (`LOOPYARD_DOCKER_TESTS=1
  … --include docker`); the default suite never reaches Docker. `test_helper.exs`
  snapshots the test-prefixed volume names at start (`snapshot/0`) and, after
  the suite, `sweep/1` removes the ones that appeared during the run AND are
  dangling — through the same `Loopyard.GC` selection `mix loopyard.gc` uses
  (`:only_volumes`), so the same refusals apply (no homes, no compose volumes,
  never under a live prefix). Removal is not forced: a volume another run is
  using stays.
  """

  alias Loopyard.{Docker, GC}
  alias Loopyard.GC.Runner

  @doc """
  Test-prefixed volume AND container names present now, or nil when Docker is
  off. Containers are in it so the containers this run leaves behind can go
  first (`sweep/1`): a work container started by a test stayed up for hours
  after the run, holding its memory and pinning its volumes.
  """
  def snapshot do
    if Docker.daemon_available?() do
      case Runner.listings() do
        {:ok, l} -> names_under_test_prefix(resource_names(l))
        _ -> nil
      end
    end
  end

  @doc """
  Remove what this run created under the test prefix: its containers (forced
  — nothing real runs under the test prefix, and a run that is over is not
  using them), then its dangling volumes. Returns how many things went.
  """
  def sweep(nil), do: 0

  def sweep(before) do
    with {:ok, l} <- Runner.listings() do
      created = created_since(before, resource_names(l))

      containers =
        for c <- l.containers,
            is_binary(c.name),
            MapSet.member?(created, c.name),
            do: %{kind: :container, name: c.name, size: c.size, force: true}

      %{removed: gone} = Runner.remove(containers)
      length(gone) + sweep_volumes(created)
    else
      _ -> 0
    end
  end

  # A fresh listing: the containers just removed no longer mount anything.
  defp sweep_volumes(created) do
    with {:ok, l} <- Runner.listings(),
         {:ok, picked} <- GC.select(l, Runner.opts(only_volumes: created)) do
      %{removed: removed} = Runner.remove(Enum.filter(picked, &(&1.kind == :volume)))
      length(removed)
    else
      _ -> 0
    end
  end

  defp resource_names(l),
    do:
      Enum.map(l.volumes, & &1.name) ++
        (l.containers |> Enum.map(& &1.name) |> Enum.filter(&is_binary/1))

  @doc "Names under the test prefix in `now` that were not in `before` (pure)."
  def created_since(before, now) do
    now |> names_under_test_prefix() |> MapSet.difference(before)
  end

  defp names_under_test_prefix(names),
    do: names |> Enum.filter(&String.starts_with?(&1, GC.test_prefix())) |> MapSet.new()
end
