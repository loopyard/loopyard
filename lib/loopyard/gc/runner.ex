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
  Every id registered on THIS server that owns Docker resources: workspaces,
  projects (their canonical volumes), and workstations (`ws-<id>`). Read from
  the live registries AND the on-disk project store, so a registry that has
  not finished loading still knows its own (`GC.Review` treats "nothing
  registered" as "not loaded" and offers no leftovers at all).
  """
  @spec known_ids() :: [String.t()]
  def known_ids do
    registered =
      for {id, ws} <- safe(fn -> :ets.tab2list(:workspace_registry) end, []),
          v <- [id, ws[:project_id]],
          is_binary(v),
          do: v

    stored =
      for {project_id, entry} <- safe(&Loopyard.CanonicalStore.load/0, %{}),
          v <- [project_id | stored_workspace_ids(entry)],
          is_binary(v),
          do: v

    projects = for p <- safe(&Loopyard.ProjectRegistry.list_projects/0, []), do: p.id
    stations = for id <- safe(&Loopyard.Workstation.list/0, []), do: "ws-" <> id

    case Enum.uniq(registered ++ stored ++ projects) do
      # No workspace or project known: the registries are not loaded (or this
      # is a fresh install). Either way nothing may be called "unknown".
      [] -> []
      ids -> ids ++ stations
    end
  end

  defp stored_workspace_ids(%{"workspaces" => list}) when is_list(list),
    do: for(%{"id" => id} <- list, do: id)

  defp stored_workspace_ids(%{"workspaces" => %{} = map}), do: Map.keys(map)
  defp stored_workspace_ids(_), do: []

  defp safe(fun, fallback) do
    fun.()
  rescue
    _ -> fallback
  catch
    _, _ -> fallback
  end

  @doc """
  One look at the daemon, sorted both ways: `auto` is what the automatic tier
  may take (`GC.select/2`), `groups` what is left for a human to review
  (`GC.Review.groups/2`).
  """
  @spec survey() ::
          {:ok, %{auto: [GC.candidate()], groups: GC.Review.groups()}} | {:error, String.t()}
  def survey do
    with {:ok, listings} <- listings(),
         {:ok, auto} <- GC.select(listings, opts()) do
      groups =
        GC.Review.groups(listings,
          live_prefix: Docker.prefix(),
          test_prefix: GC.test_prefix(),
          known_ids: known_ids(),
          auto: auto
        )

      {:ok, %{auto: auto, groups: groups}}
    end
  end

  @doc """
  Remove the candidates. Returns `%{removed: [candidate], failed: [{candidate, reason}]}`.

  Removal is not forced, with ONE exception a caller must ask for by row
  (`force: true`): a container, which `GC.Review` sets only for a running
  container under the TEST prefix. Volumes and images are never forced.
  """
  def remove(candidates) do
    {forced, plain} = Enum.split_with(candidates, &(&1.kind == :container and &1[:force] == true))

    acc =
      Enum.reduce(forced, %{removed: [], failed: []}, fn c, a ->
        case Docker.docker(["rm", "-f", c.name], timeout: 60_000, retry: false) do
          {:ok, _} -> %{a | removed: a.removed ++ [c]}
          {:error, why} -> %{a | failed: a.failed ++ [{c, String.trim(to_string(why))}]}
        end
      end)

    # Containers first, then volumes, then images: a volume or image is free
    # of its container by the time it is tried.
    [:container, :volume, :image]
    |> Enum.flat_map(fn kind ->
      plain
      |> Enum.filter(&(&1.kind == kind))
      |> Enum.chunk_every(@batch)
      |> Enum.map(&{kind, &1})
    end)
    |> Enum.reduce(acc, &remove_batch/2)
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
