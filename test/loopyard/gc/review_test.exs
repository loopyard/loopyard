defmodule Loopyard.GC.ReviewTest do
  @moduledoc """
  What `/system/docker` offers a human to remove. The module's safety is what
  it REFUSES to list, so most of these are things that must not appear.
  """
  use ExUnit.Case, async: true

  alias Loopyard.GC
  alias Loopyard.GC.Review

  @live "loopyard-"
  @test "loopyard-test-"

  defp vol(name, opts \\ []),
    do: %{name: name, links: opts[:links] || 0, size: opts[:size] || 10, labels: ""}

  defp ctr(name, state, opts \\ []),
    do: %{
      name: name,
      state: state,
      image: opts[:image] || "some:image",
      mounts: opts[:mounts] || [],
      size: opts[:size] || 5,
      labels: ""
    }

  defp img(repo, tag, opts \\ []),
    do: %{
      id: opts[:id] || "sha256:abc",
      repository: repo,
      tag: tag,
      containers: opts[:containers] || 0,
      size: opts[:size] || 100
    }

  defp groups(listings, opts \\ []) do
    Review.groups(listings,
      live_prefix: @live,
      test_prefix: @test,
      known_ids: Keyword.get(opts, :known, ["d87b1f7a", "c857c895", "ws-brad"]),
      auto: Keyword.get(opts, :auto, [])
    )
  end

  defp names(rows), do: Enum.map(rows, & &1.name)

  defp everything(g), do: Enum.flat_map(Review.group_keys(), &names(Map.fetch!(g, &1)))

  test "a registered workspace's containers, volumes and image are never offered" do
    g =
      groups(%{
        containers: [
          ctr("loopyard-d87b1f7a-dev-1", "exited", image: "loopyard-d87b1f7a-dev"),
          ctr("loopyard-ws-brad", "exited")
        ],
        volumes: [
          vol("loopyard-d87b1f7a-code"),
          vol("loopyard-d87b1f7a_pgdata"),
          vol("loopyard-c857c895-canonical"),
          vol("loopyard-ws-brad-home")
        ],
        images: [img("loopyard-d87b1f7a-dev", "latest"), img("loopyard-workspace-base", "v5")]
      })

    assert everything(g) == []
  end

  test "an id is never matched as the start of a longer id" do
    assert Review.owned?("loopyard-534d-code", @live, ["534d"])
    assert Review.owned?("loopyard-534d_pgdata", @live, ["534d"])
    assert Review.owned?("loopyard-534d", @live, ["534d"])
    refute Review.owned?("loopyard-534d9-code", @live, ["534d"])
    refute Review.owned?("loopyard-534", @live, ["534d"])
    refute Review.owned?("other-534d-code", @live, ["534d"])
    refute Review.owned?("loopyard-534d-code", @live, ["", nil])
  end

  test "an unregistered workspace's stopped leftovers are the unknown group" do
    g =
      groups(%{
        containers: [
          ctr("loopyard-62ddecea-dev-1", "exited",
            image: "loopyard-62ddecea-dev",
            mounts: ["loopyard-62ddecea-code"]
          )
        ],
        volumes: [
          vol("loopyard-62ddecea-code", links: 1, size: 500),
          vol("loopyard-62ddecea_dind-data", size: 9_000)
        ],
        images: [img("loopyard-62ddecea-dev", "latest", containers: 1)]
      })

    assert names(g.unknown) == [
             "loopyard-62ddecea_dind-data",
             "loopyard-62ddecea-code",
             "loopyard-62ddecea-dev:latest",
             "loopyard-62ddecea-dev-1"
           ]

    # Containers go first, so the volume and image they hold are free by then.
    assert g.unknown |> Review.removal_order() |> hd() |> Map.fetch!(:kind) == :container
    assert Enum.all?(g.unknown, &(&1.force == false))
    assert g.stopped_containers == [] and g.unused_images == [] and g.other_volumes == []
  end

  test "a RUNNING container under the live prefix is never offered, nor what it mounts" do
    g =
      groups(%{
        containers: [
          ctr("loopyard-aaaa1111-work", "running", mounts: ["loopyard-aaaa1111-code"])
        ],
        volumes: [vol("loopyard-aaaa1111-code", links: 1), vol("loopyard-aaaa1111_cache")],
        images: []
      })

    # Its unmounted compose volume is still a leftover candidate; the live
    # container and the volume it mounts are not.
    assert names(g.unknown) == ["loopyard-aaaa1111_cache"]
  end

  test "a running container under the TEST prefix is a leftover, offered with force" do
    g =
      groups(%{
        containers: [
          ctr("loopyard-test-17b27c37-work", "running", mounts: ["loopyard-test-17b27c37-code"])
        ],
        volumes: [vol("loopyard-test-17b27c37-code", links: 1)],
        images: []
      })

    assert [%{name: "loopyard-test-17b27c37-work", force: true, note: "running"}] = g.unknown
  end

  test "nothing is 'unknown' when no id is registered: an empty registry is not loaded" do
    g =
      groups(
        %{
          containers: [ctr("loopyard-62ddecea-dev-1", "exited")],
          volumes: [vol("loopyard-62ddecea-code")],
          images: [img("loopyard-62ddecea-dev", "latest")]
        },
        known: []
      )

    assert g.unknown == []
    # And they do not leak into the other groups either.
    assert everything(g) == []
  end

  test "in-flight sign-in and copy throwaways are not leftovers" do
    g =
      groups(%{
        containers: [
          ctr("loopyard-signin-brad-12", "running", image: "loopyard-workspace-base:v5"),
          ctr("loopyard-cp-99", "created", image: "alpine")
        ],
        volumes: [],
        images: []
      })

    assert everything(g) == []
  end

  test "what the automatic tier takes is not offered twice" do
    listings = %{
      containers: [],
      volumes: [vol("loopyard-test-abc1-code")],
      images: [img("loopyard-workspace-base", "v4")]
    }

    {:ok, auto} =
      GC.select(listings,
        live_prefix: @live,
        test_prefix: @test,
        current_image: "loopyard-workspace-base:v5"
      )

    assert length(auto) == 2
    assert everything(groups(listings, auto: auto)) == []
  end

  test "other tools' stopped containers, unused images and unattached volumes" do
    g =
      groups(%{
        containers: [
          ctr("great_yalow", "exited", image: "2b01faeedd31", mounts: ["held"]),
          ctr("gbrain-db", "running", mounts: ["gbrain_pgdata"])
        ],
        volumes: [
          vol("observatory_system", size: 14_000),
          vol("held", links: 1),
          vol("gbrain_pgdata", links: 1),
          vol("trivy-cache", size: 1_600)
        ],
        images: [
          img("node", "24-trixie", size: 1_200),
          img("<none>", "<none>", id: "sha256:086123918dfb", size: 5_000),
          img("postgres", "16", containers: 2)
        ]
      })

    assert names(g.stopped_containers) == ["great_yalow"]
    # An untagged image is handled by its id.
    assert names(g.unused_images) == ["sha256:086123918dfb", "node:24-trixie"]
    assert Enum.find(g.unused_images, &(&1.name == "sha256:086123918dfb")).note == "untagged"
    # Unattached only: nothing a container (running or stopped) mounts.
    assert names(g.other_volumes) == ["observatory_system", "trivy-cache"]
    assert g.unknown == []
    assert Review.total(g.other_volumes) == 15_600
  end
end
