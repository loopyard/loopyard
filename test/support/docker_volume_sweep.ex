defmodule Loopyard.Test.DockerVolumeSweep do
  @moduledoc """
  The test suite removes the Docker volumes it creates (issue #117).

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

  @doc "Test-prefixed volume names present now, or nil when Docker is off."
  def snapshot do
    if Docker.daemon_available?() do
      case Runner.listings() do
        {:ok, l} -> l.volumes |> Enum.map(& &1.name) |> names_under_test_prefix()
        _ -> nil
      end
    end
  end

  @doc "Remove the dangling test volumes created since `before`. Returns the count."
  def sweep(nil), do: 0

  def sweep(before) do
    with {:ok, l} <- Runner.listings(),
         created = created_since(before, Enum.map(l.volumes, & &1.name)),
         {:ok, picked} <- GC.select(l, Runner.opts(only_volumes: created)) do
      volumes = Enum.filter(picked, &(&1.kind == :volume))
      %{removed: removed} = Runner.remove(volumes)
      length(removed)
    else
      _ -> 0
    end
  end

  @doc "Names under the test prefix in `now` that were not in `before` (pure)."
  def created_since(before, now) do
    now |> names_under_test_prefix() |> MapSet.difference(before)
  end

  defp names_under_test_prefix(names),
    do: names |> Enum.filter(&String.starts_with?(&1, GC.test_prefix())) |> MapSet.new()
end
