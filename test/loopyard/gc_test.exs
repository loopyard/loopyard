defmodule Loopyard.GCTest do
  @moduledoc """
  `mix loopyard.gc`'s selection. The safety of the command is this module:
  every test here that asserts something is NOT selected is the point.
  Fixture names are the real shapes seen on a full Colima VM (Nov 2026).
  """
  use ExUnit.Case, async: true

  alias Loopyard.GC

  @opts [
    live_prefix: "loopyard-",
    test_prefix: "loopyard-test-",
    current_image: "loopyard-workspace-base:v5"
  ]

  defp vol(name, opts \\ []) do
    %{
      name: name,
      links: Keyword.get(opts, :links, 0),
      size: Keyword.get(opts, :size, 29_000),
      labels: Keyword.get(opts, :labels, "")
    }
  end

  defp ctr(name, opts) do
    %{
      name: name,
      state: Keyword.get(opts, :state, "exited"),
      image: Keyword.get(opts, :image, "loopyard-workspace-base:v5"),
      mounts: Keyword.get(opts, :mounts, []),
      size: Keyword.get(opts, :size, 0),
      labels: Keyword.get(opts, :labels, "")
    }
  end

  defp img(repo, tag, opts \\ []) do
    %{
      repository: repo,
      tag: tag,
      containers: Keyword.get(opts, :containers, 0),
      size: Keyword.get(opts, :size, 2_480_000_000)
    }
  end

  defp names(listings, opts \\ @opts) do
    {:ok, picked} =
      GC.select(Map.merge(%{volumes: [], containers: [], images: []}, listings), opts)

    Enum.map(picked, & &1.name)
  end

  describe "volumes" do
    test "dangling test-suite workspace volumes are selected" do
      vols =
        for n <- ~w(loopyard-test-1e82-code loopyard-test-17b27c37-code
                    loopyard-test-vol-ws-123-code loopyard-test-9d53-cache
                    loopyard-test-abc123-canonical loopyard-test-nonexistent-ws-ab12cd-code),
            do: vol(n)

      assert Enum.sort(names(%{volumes: vols})) == Enum.sort(Enum.map(vols, & &1.name))
    end

    test "a LIVE workspace's volumes are never selected, dangling or not" do
      for n <- ~w(loopyard-3e57c067-code loopyard-a866-code loopyard-62ddecea-cache
                  loopyard-abc-canonical loopyard-vol-ws-1-code loopyard-nonexistent-ws-x-code) do
        assert names(%{volumes: [vol(n)]}) == [], "#{n} selected"
      end
    end

    test "workstation homes are never selected — live or test, any shape" do
      for n <- ~w(loopyard-ws-brad-home loopyard-test-ws-brad-home
                  loopyard-test-ws-acct-d70517-home loopyard-test-ws-write-file-test-code
                  loopyard-test-foo-home loopyard-ws-envtest-1-home) do
        assert names(%{volumes: [vol(n, size: 144_300_000)]}) == [], "#{n} selected"
      end
    end

    test "compose project volumes are never selected (label or `_` naming)" do
      labels = "com.docker.compose.project=loopyard-test-ab,com.docker.compose.volume=code"

      assert names(%{
               volumes: [
                 vol("loopyard-test-ab-code", labels: labels),
                 vol("loopyard-test-ab_pgdata"),
                 vol("loopyard-test-ab_dind-data-code"),
                 vol("loopyard-62ddecea_dind-data")
               ]
             }) == []
    end

    test "a volume any container mounts — running OR stopped — is never selected" do
      v = vol("loopyard-test-17b27c37-code")

      assert names(%{volumes: [%{v | links: 1}]}) == []

      # Links says 0 (stale), but a stopped container still mounts it.
      stopped = ctr("loopyard-test-17b27c37-work", state: "exited", mounts: [v.name])
      assert names(%{volumes: [v], containers: [stopped]}) == []
    end

    test "names that don't carry a Loopyard-owned test name are never selected" do
      for n <-
            ~w(code-123 code-nonexistent-ws-ab code-loopyard-test-1-code gbrain-gbrain-machine-1
               observatory_system_rpi3-mpwYeSrNP5Q_ydJG trivy-cache
               0abb14d42671c3378e267a8a9729b5c1d20f910da15dc6cbdfae6e9c70859a7b
               loopyard-testx-1-code loopyard-test--code loopyard-test-code
               loopyard-test-1-code-backup loopyard-test-1-codes xloopyard-test-1-code
               loopyard-TEST-1-code loopyard-test-1-data) do
        assert names(%{volumes: [vol(n)]}) == [], "#{n} selected"
      end
    end

    test "names with path, glob or shell characters are never selected" do
      for n <- [
            "loopyard-test-1-code ",
            " loopyard-test-1-code",
            "loopyard-test-a b-code",
            "loopyard-test-../x-code",
            "loopyard-test-*-code",
            "loopyard-test-$(rm)-code",
            "loopyard-test-1;rm-code",
            "loopyard-test-1\n-code",
            "loopyard-test-1-code\n",
            "/loopyard-test-1-code"
          ] do
        assert names(%{volumes: [vol(n)]}) == [], "#{inspect(n)} selected"
      end
    end

    test "an unparseable link count reads as IN USE" do
      json =
        Jason.encode!(%{
          "Volumes" => [
            %{"Name" => "loopyard-test-1-code", "Links" => "N/A", "Size" => "1kB", "Labels" => ""}
          ]
        })

      {:ok, listings} = GC.from_system_df(json)
      assert names(listings) == []
    end

    test ":only_volumes narrows to a given set (the suite's own cleanup)" do
      vols = [vol("loopyard-test-1-code"), vol("loopyard-test-2-code")]

      assert names(
               %{volumes: vols},
               @opts ++ [only_volumes: MapSet.new(["loopyard-test-2-code"])]
             ) ==
               ["loopyard-test-2-code"]
    end
  end

  describe "the environment's own prefix" do
    test "refuses everything when the live prefix IS the test prefix" do
      opts = Keyword.put(@opts, :live_prefix, "loopyard-test-")
      assert {:error, msg} = GC.select(%{volumes: [vol("loopyard-test-1-code")]}, opts)
      assert msg =~ "live"
    end

    test "refuses when the live prefix lies under the test prefix" do
      opts = Keyword.put(@opts, :live_prefix, "loopyard-test-x-")
      assert {:error, _} = GC.select(%{volumes: [vol("loopyard-test-x-1-code")]}, opts)
    end

    test "refuses malformed prefixes (an empty prefix would match everything)" do
      for {live, test} <- [{"", "loopyard-test-"}, {"loopyard-", ""}, {"loopyard-", "*"}] do
        opts = @opts |> Keyword.put(:live_prefix, live) |> Keyword.put(:test_prefix, test)
        assert {:error, _} = GC.select(%{volumes: [vol("loopyard-test-1-code")]}, opts)
      end
    end
  end

  describe "containers" do
    test "stopped sign-in and copy throwaways are selected, under either prefix" do
      cs = [
        ctr("loopyard-signin-acct1-123", state: "exited"),
        ctr("loopyard-cp-4711", state: "created", image: "alpine"),
        ctr("loopyard-test-signin-brad-9", state: "dead"),
        ctr("loopyard-test-cp-12", state: "exited", image: "alpine:3.20")
      ]

      assert Enum.sort(names(%{containers: cs})) == Enum.sort(Enum.map(cs, & &1.name))
    end

    test "a running throwaway is never selected" do
      for state <- ~w(running restarting paused removing) do
        assert names(%{containers: [ctr("loopyard-signin-a-1", state: state)]}) == []
      end
    end

    test "work, workstation and compose containers are never selected, even stopped" do
      for n <- ~w(loopyard-038d9093-work loopyard-ws-brad loopyard-038d9093-dev-1
                  loopyard-62ddecea-dind-1 loopyard-test-17b27c37-work loopyard-038d9093-postgres-1
                  loopyard-signin loopyard-signin- loopyard-signinx-1 loopyard-cpx-1
                  zealous_fermi oc-check gbrain-test-pg signin-1 x-loopyard-signin-1) do
        assert names(%{containers: [ctr(n, state: "exited")]}) == [], "#{n} selected"
      end
    end

    test "a throwaway NAME on the wrong image is never selected" do
      # A workspace with an unlucky id: `loopyard-signin-x-dev-1` is its compose
      # dev container; a `cp-` name must also be the alpine copy helper.
      for c <- [
            ctr("loopyard-signin-x-dev-1", image: "loopyard-signin-x-dev"),
            ctr("loopyard-signin-x-work", image: "loopyard-workspace-base:v5"),
            ctr("loopyard-cp-1", image: "loopyard-workspace-base:v5"),
            ctr("loopyard-cp-1x", image: "alpine"),
            ctr("loopyard-cp-1", image: "alpinex")
          ] do
        assert names(%{containers: [c]}) == [], "#{c.name} (#{c.image}) selected"
      end
    end

    test "a compose-labelled container is never selected, whatever its name" do
      c =
        ctr("loopyard-signin-a-1",
          state: "exited",
          labels: "com.docker.compose.project=loopyard-a"
        )

      assert names(%{containers: [c]}) == []
    end
  end

  describe "images" do
    test "superseded base-image tags used by nothing are selected" do
      assert names(%{
               images: [
                 img("loopyard-workspace-base", "v4"),
                 img("loopyard-workspace-base", "v3")
               ]
             }) ==
               ["loopyard-workspace-base:v4", "loopyard-workspace-base:v3"]
    end

    test "the current tag is never selected" do
      assert names(%{images: [img("loopyard-workspace-base", "v5")]}) == []
    end

    test "a tag any container uses is never selected (count or listing)" do
      assert names(%{images: [img("loopyard-workspace-base", "v4", containers: 1)]}) == []

      c = ctr("loopyard-038d9093-work", state: "running", image: "loopyard-workspace-base:v4")
      assert names(%{images: [img("loopyard-workspace-base", "v4")], containers: [c]}) == []
    end

    test "other repositories and untagged images are never selected" do
      for {repo, tag} <- [
            {"loopyard-038d9093-dev", "latest"},
            {"loopyard-ws-brad", "latest"},
            {"<none>", "<none>"},
            {"loopyard-workspace-base", "<none>"},
            {"loopyard-workspace-base-evil", "v1"},
            {"postgres", "16"}
          ] do
        assert names(%{images: [img(repo, tag)]}) == [], "#{repo}:#{tag} selected"
      end
    end
  end

  test "candidates are sorted largest first per kind; total sums them" do
    {:ok, picked} =
      GC.select(
        %{
          volumes: [vol("loopyard-test-1-code", size: 10), vol("loopyard-test-2-code", size: 30)],
          containers: [],
          images: [img("loopyard-workspace-base", "v4", size: 100)]
        },
        @opts
      )

    assert Enum.map(picked, & &1.name) ==
             ["loopyard-test-2-code", "loopyard-test-1-code", "loopyard-workspace-base:v4"]

    assert GC.total(picked) == 140
  end

  test "largest_other/3 lists what else is big, never a candidate" do
    listings = %{
      volumes: [
        vol("loopyard-test-1-code", size: 1),
        vol("loopyard-62ddecea_dind-data", links: 1, size: 8_746_000_000),
        vol("trivy-cache", size: 1_642_000_000)
      ],
      containers: [],
      images: [img("loopyard-038d9093-dev", "latest", size: 441_900_000)]
    }

    {:ok, picked} = GC.select(listings, @opts)
    others = GC.largest_other(listings, picked, 2)
    assert Enum.map(others, & &1.name) == ["loopyard-62ddecea_dind-data", "trivy-cache"]
  end

  describe "from_system_df/1" do
    test "parses the real `docker system df -v --format '{{json .}}'` shape" do
      json =
        Jason.encode!(%{
          "Images" => [
            %{
              "Containers" => "5",
              "Repository" => "loopyard-workspace-base",
              "Tag" => "v5",
              "Size" => "2.48GB",
              "UniqueSize" => "0B"
            }
          ],
          "Containers" => [
            %{
              "Names" => "loopyard-test-17b27c37-work",
              "State" => "running",
              "Image" => "loopyard-workspace-base:v5",
              "Mounts" => "loopyard-test-ws-brad-home,loopyard-test-17b27c37-code",
              "Size" => "0B",
              "Labels" => ""
            }
          ],
          "Volumes" => [
            %{
              "Name" => "loopyard-test-1e82-code",
              "Links" => "0",
              "Size" => "28.72kB",
              "Labels" => ""
            }
          ],
          "BuildCache" => []
        })

      assert {:ok, %{volumes: [v], containers: [c], images: [i]}} = GC.from_system_df(json)
      assert v == %{name: "loopyard-test-1e82-code", links: 0, size: 28_720, labels: ""}
      assert c.mounts == ["loopyard-test-ws-brad-home", "loopyard-test-17b27c37-code"]
      assert i.containers == 5 and i.size == 0
    end

    test "rejects non-JSON" do
      assert {:error, _} = GC.from_system_df("Cannot connect to the Docker daemon")
    end
  end

  test "parse_size/1" do
    assert GC.parse_size("0B") == 0
    assert GC.parse_size("28.72kB") == 28_720
    assert GC.parse_size("1.666GB") == 1_666_000_000
    assert GC.parse_size("144.3MB") == 144_300_000
    assert GC.parse_size("N/A") == 0
    assert GC.parse_size(nil) == 0
  end
end
