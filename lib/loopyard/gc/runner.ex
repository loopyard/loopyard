defmodule Loopyard.GC.Runner do
  @moduledoc """
  The impure half of `mix loopyard.gc`: read the Docker listings, hand them to
  the pure `Loopyard.GC` selection, and — only when asked — remove what it
  picked. Removal is NEVER forced (`docker volume rm`, `docker rm`,
  `docker image rm`, no `-f`), so anything that came into use since the
  listing is refused by Docker itself and reported, not removed.
  """

  alias Loopyard.{Docker, GC}

  @batch 100

  @doc "The listings from one `docker system df -v` call."
  @spec listings() :: {:ok, GC.listings()} | {:error, String.t()}
  def listings do
    case Docker.docker(["system", "df", "-v", "--format", "{{json .}}"],
           timeout: 120_000,
           retry: false
         ) do
      {:ok, out} ->
        GC.from_system_df(out)

      {:error, out} ->
        {:error, "docker system df failed: #{String.slice(to_string(out), 0, 300)}"}
    end
  end

  @doc "The selection opts for THIS environment."
  def opts(extra \\ []) do
    [
      live_prefix: Docker.prefix(),
      test_prefix: GC.test_prefix(),
      current_image: Loopyard.Workspace.WorkContainer.image()
    ] ++ extra
  end

  @doc """
  Remove the candidates. Returns `%{removed: [candidate], failed: [{candidate, reason}]}`.
  """
  def remove(candidates) do
    candidates
    |> Enum.group_by(& &1.kind)
    |> Enum.flat_map(fn {kind, list} ->
      list |> Enum.chunk_every(@batch) |> Enum.map(&{kind, &1})
    end)
    |> Enum.reduce(%{removed: [], failed: []}, &remove_batch/2)
  end

  defp remove_batch({kind, batch}, acc) do
    case Docker.docker(rm_args(kind) ++ Enum.map(batch, & &1.name),
           timeout: 120_000,
           retry: false
         ) do
      {:ok, _} ->
        %{acc | removed: acc.removed ++ batch}

      {:error, _} ->
        # A batch fails as a whole when one name is refused; go one by one so
        # each refusal is named and the rest still go.
        Enum.reduce(batch, acc, fn c, a ->
          case Docker.docker(rm_args(kind) ++ [c.name], timeout: 30_000, retry: false) do
            {:ok, _} -> %{a | removed: a.removed ++ [c]}
            {:error, why} -> %{a | failed: a.failed ++ [{c, String.trim(to_string(why))}]}
          end
        end)
    end
  end

  defp rm_args(:volume), do: ["volume", "rm"]
  defp rm_args(:container), do: ["rm"]
  defp rm_args(:image), do: ["image", "rm"]
end
