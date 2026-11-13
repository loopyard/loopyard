defmodule Loopyard.GC.Review do
  @moduledoc """
  What is filling the Docker disk that Loopyard will NOT remove on its own —
  sorted into groups a human can clear from `/system/docker`, each with its
  own warning. Pure: Docker listings and the registered ids come in as data.

  `Loopyard.GC.select/2` is the automatic tier: provably Loopyard's own and
  provably unused. Everything here failed one of those two tests, which is
  exactly why a person has to say yes:

    * `:stopped_containers` — stopped containers that are NOT Loopyard's
      (another tool's, an old `docker run`). Their volumes are kept.
    * `:unused_images` — images no container uses, other than the base image
      in service and a registered workspace's own dev image. Pulled or rebuilt
      when next needed; costs time, not data.
    * `:unknown` — things named like Loopyard's (`loopyard-<id>…`) whose id is
      not registered on THIS server: a deleted workspace's leftovers, an old
      test run's, or — the reason this is never automatic — a workspace that
      belongs to ANOTHER Loopyard sharing this Docker daemon, or to this one
      before its registry finished loading. Containers, images and EMPTY
      volumes only: nothing in this group holds a byte of anyone's work, so
      it may go in bulk.
    * `:unknown_data` — the same unregistered ids' volumes that have something
      in them: code (uncommitted and unpushed work included), a database, a
      cache. Loopyard cannot tell which, so they go one at a time, never in
      bulk. (The first real run of this page found months-old workspaces with
      unpushed commits here; one bulk button would have taken them.)
    * `:other_volumes` — unattached volumes with other names. Real data, one
      at a time, never in bulk.

  ## What is never offered

    * Anything the automatic tier already takes.
    * Anything owned by a registered id (workspace, project, workstation).
    * A RUNNING container under the live prefix, and so, because removal is
      never forced, the volumes it mounts. If the registry is wrong, a live
      workspace still cannot be taken apart from here. (A running container
      under the TEST prefix is a test run's leftover and is offered; nothing
      real runs under that prefix.)
    * A volume a running container mounts, whoever owns it.
    * Either `:unknown` group at all when no id is registered — an empty registry
      means "not loaded", not "nothing is mine". (`GC.Runner.known_ids/0`
      returns none when no WORKSPACE or PROJECT is known, even if workstations
      are, for the same reason.)
  """

  alias Loopyard.GC

  @stopped ~w(exited created dead)
  @base_repo "loopyard-workspace-base"

  @type row :: %{
          kind: :volume | :container | :image,
          name: String.t(),
          size: integer(),
          note: String.t() | nil,
          force: boolean()
        }
  @type groups :: %{
          stopped_containers: [row()],
          unused_images: [row()],
          unknown: [row()],
          unknown_data: [row()],
          other_volumes: [row()]
        }

  @groups [:stopped_containers, :unused_images, :unknown, :unknown_data, :other_volumes]

  @doc "The group keys, in display order."
  def group_keys, do: @groups

  @doc """
  Sort `listings` into the reviewable groups.

  Opts (all required): `:live_prefix`, `:test_prefix`, `:known_ids` (every
  workspace, project and `ws-<workstation>` id registered here), and
  `:auto` — the automatic tier's candidates for the same listings, which are
  excluded.
  """
  @spec groups(GC.listings(), keyword()) :: groups()
  def groups(listings, opts) do
    live = Keyword.fetch!(opts, :live_prefix)
    test = Keyword.fetch!(opts, :test_prefix)
    known = Keyword.fetch!(opts, :known_ids)
    auto = MapSet.new(Keyword.fetch!(opts, :auto), &{&1.kind, &1.name})

    containers = listings[:containers] || []
    volumes = listings[:volumes] || []
    images = listings[:images] || []
    mounted = containers |> Enum.flat_map(&(&1[:mounts] || [])) |> MapSet.new()

    # What a RUNNING container mounts is in use, whoever it belongs to: never
    # listed (Docker would refuse it anyway, and a row for it only invites a
    # tap on something live).
    live_mounts =
      containers
      |> Enum.reject(&(&1.state in @stopped))
      |> Enum.flat_map(&(&1[:mounts] || []))
      |> MapSet.new()

    ours? = fn name -> is_binary(name) and (under?(name, live) or under?(name, test)) end
    known? = fn name -> owned?(name, live, known) end
    auto? = fn kind, name -> MapSet.member?(auto, {kind, name}) end

    unknown =
      if known == [] do
        []
      else
        unknown_containers(containers, live, test, ours?, known?, auto?) ++
          unknown_volumes(volumes, live_mounts, ours?, known?, auto?) ++
          unknown_images(images, ours?, known?, auto?)
      end

    # A volume with something in it is somebody's code, database or cache.
    # It never rides along with a bulk removal.
    {unknown_data, unknown} = Enum.split_with(unknown, &(&1.kind == :volume and &1.size > 0))

    %{
      stopped_containers:
        by_size(
          for c <- containers,
              c.state in @stopped,
              is_binary(c.name),
              not ours?.(c.name),
              do: row(:container, c.name, c.size, c.image)
        ),
      unused_images:
        by_size(
          for i <- images,
              i.containers == 0,
              ref = image_ref(i),
              is_binary(ref),
              not ours?.(i.repository),
              not auto?.(:image, ref),
              do: row(:image, ref, i.size, image_note(i))
        ),
      unknown: by_size(unknown),
      unknown_data: by_size(unknown_data),
      other_volumes:
        by_size(
          for v <- volumes,
              is_binary(v.name),
              v.links == 0,
              not MapSet.member?(mounted, v.name),
              not ours?.(v.name),
              do: row(:volume, v.name, v.size, nil)
        )
    }
  end

  @doc "Bytes in a list of rows."
  def total(rows), do: rows |> Enum.map(& &1.size) |> Enum.sum()

  @doc """
  The order to remove a group in: containers, then volumes, then images, so a
  volume or image is free of its (removed) container by the time it is tried.
  """
  def removal_order(rows) do
    Enum.sort_by(rows, fn
      %{kind: :container} -> 0
      %{kind: :volume} -> 1
      %{kind: :image} -> 2
    end)
  end

  # ── the unknown group ──────────────────────────────────────────────────

  defp unknown_containers(containers, live, test, ours?, known?, auto?) do
    for c <- containers,
        is_binary(c.name),
        ours?.(c.name),
        not known?.(c.name),
        not auto?.(:container, c.name),
        not GC.throwaway?(c, [live, test]),
        running? <- [c.state not in @stopped],
        # A running container under the LIVE prefix may be a real workspace
        # this server does not know about. Never offered.
        not running? or under?(c.name, test) do
      row(:container, c.name, c.size, (running? && "running") || c.image, running?)
    end
  end

  defp unknown_volumes(volumes, live_mounts, ours?, known?, auto?) do
    for v <- volumes,
        is_binary(v.name),
        not MapSet.member?(live_mounts, v.name),
        ours?.(v.name),
        not known?.(v.name),
        not auto?.(:volume, v.name),
        do: row(:volume, v.name, v.size, (v.links > 0 && "held by a stopped container") || nil)
  end

  defp unknown_images(images, ours?, known?, auto?) do
    for i <- images,
        is_binary(i.repository),
        i.repository != @base_repo,
        ours?.(i.repository),
        not known?.(i.repository),
        ref = image_ref(i),
        is_binary(ref),
        not auto?.(:image, ref),
        do: row(:image, ref, i.size, nil)
  end

  # ── ownership ──────────────────────────────────────────────────────────

  @doc false
  # `<prefix><id>` exactly, or followed by the `-`/`_` that starts a suffix
  # (`-code`, `-work`, `-dev-1`, compose's `_pgdata`). An id is never matched
  # as a mere prefix of a longer id.
  def owned?(name, prefix, known_ids) when is_binary(name) do
    case String.split_at(name, String.length(prefix)) do
      {^prefix, rest} ->
        Enum.any?(known_ids, fn id ->
          is_binary(id) and id != "" and
            (rest == id or String.starts_with?(rest, id <> "-") or
               String.starts_with?(rest, id <> "_"))
        end)

      _ ->
        false
    end
  end

  def owned?(_, _, _), do: false

  defp under?(name, prefix), do: is_binary(name) and String.starts_with?(name, prefix)

  # ── rows ───────────────────────────────────────────────────────────────

  defp row(kind, name, size, note, force \\ false),
    do: %{kind: kind, name: name, size: size || 0, note: note, force: force}

  # An untagged image has no name to remove it by; its id is the handle.
  defp image_ref(%{repository: repo, tag: tag} = i) do
    if repo in [nil, "", "<none>"] or tag in [nil, "", "<none>"],
      do: i[:id],
      else: "#{repo}:#{tag}"
  end

  defp image_note(%{repository: repo}) when repo in [nil, "", "<none>"], do: "untagged"
  defp image_note(_), do: nil

  defp by_size(list), do: Enum.sort_by(list, &{-&1.size, &1.name})
end
