defmodule Loopyard.GC do
  @moduledoc """
  What `mix loopyard.gc` may reclaim — pure selection over Docker listings
  passed in as DATA (issue #117). The safety of the command IS this module, so
  it selects only what is provably Loopyard's own AND provably unused, and
  every rule is a reason to say NO:

    * **Volumes** — dangling (no container, running or stopped, mounts it),
      named `<test prefix><id>-code|-cache|-canonical` (the shapes the test
      suite's workspaces create), no compose labels, no `_` (compose's
      `<project>_<volume>` naming). Never a workstation home (`…ws-…`,
      `…-home`), never a live workspace's volume — the live prefix is
      `loopyard-`, and the test prefix must differ from it or nothing is
      selected at all.
    * **Containers** — stopped (`exited`/`created`/`dead`) throwaways Loopyard
      names itself, matched by name AND image: `<prefix>signin-<id>-<n>` on the
      base image (the in-app sign-in) and `<prefix>cp-<n>` on alpine
      (`VolumeIO`'s copy helper), under the live or the test prefix, no
      compose labels.
    * **Images** — tags of the base image (`loopyard-workspace-base`) other
      than the one `Loopyard.Workspace.WorkContainer` runs, used by no
      container.

  Docker's own refusals stand behind this: removal is never forced, so a
  volume or image something started using since the listing stays.

  Everything else that is large is REPORTED (`largest_other/2`), never
  selected — deciding about a project's compose data is the owner's call.
  """

  @base_repo "loopyard-workspace-base"
  @volume_shapes ~w(-code -cache -canonical)
  @stopped ~w(exited created dead)

  @type volume :: %{name: String.t(), links: integer(), size: integer(), labels: String.t()}
  @type container :: %{
          name: String.t(),
          state: String.t(),
          image: String.t(),
          mounts: [String.t()],
          size: integer(),
          labels: String.t()
        }
  @type image :: %{
          repository: String.t(),
          tag: String.t(),
          containers: integer(),
          size: integer()
        }
  @type listings :: %{volumes: [volume()], containers: [container()], images: [image()]}
  @type candidate :: %{kind: :volume | :container | :image, name: String.t(), size: integer()}

  @doc "The test-suite resource prefix gc reclaims volumes under."
  def test_prefix, do: "loopyard-test-"

  @doc """
  Every candidate, volumes then containers then images, each list sorted by
  size (largest first).

  Opts (all required — the caller states its world, nothing is defaulted from
  config here): `:live_prefix` (the running environment's `Docker.prefix/0`),
  `:test_prefix`, `:current_image` (`"loopyard-workspace-base:vN"`). Optional
  `:only_volumes` — a set of names; volumes outside it are never selected
  (the test suite's after-run cleanup of just what it created).
  """
  @spec select(listings(), keyword()) :: {:ok, [candidate()]} | {:error, String.t()}
  def select(listings, opts) do
    live = Keyword.fetch!(opts, :live_prefix)
    test = Keyword.fetch!(opts, :test_prefix)

    cond do
      not valid_prefix?(live) or not valid_prefix?(test) ->
        {:error,
         "refusing: prefixes must look like `name-` (got #{inspect(live)}, #{inspect(test)})"}

      live == test or String.starts_with?(live, test) ->
        {:error,
         "refusing: this environment's live prefix #{inspect(live)} is the test prefix — " <>
           "its test-looking volumes are live ones"}

      true ->
        mounted = mounted_names(listings[:containers] || [])

        {:ok,
         by_size(volumes(listings[:volumes] || [], test, mounted, opts[:only_volumes])) ++
           by_size(containers(listings[:containers] || [], [live, test])) ++
           by_size(images(listings[:images] || [], listings[:containers] || [], opts))}
    end
  end

  @doc "Sum of candidate sizes in bytes."
  def total(candidates), do: candidates |> Enum.map(& &1.size) |> Enum.sum()

  @doc """
  The `n` largest volumes and images that are NOT candidates — what else is
  filling the disk, for the human to decide about.
  """
  def largest_other(listings, candidates, n \\ 8) do
    picked = MapSet.new(candidates, &{&1.kind, &1.name})

    vols = for v <- listings[:volumes] || [], do: %{kind: :volume, name: v.name, size: v.size}

    imgs =
      for i <- listings[:images] || [],
          do: %{kind: :image, name: "#{i.repository}:#{i.tag}", size: i.size}

    (vols ++ imgs)
    |> Enum.reject(&MapSet.member?(picked, {&1.kind, &1.name}))
    |> Enum.sort_by(& &1.size, :desc)
    |> Enum.take(n)
  end

  # ── volumes ────────────────────────────────────────────────────────────

  defp volumes(volumes, test, mounted, only) do
    for v <- volumes,
        is_binary(v.name),
        test_volume?(v.name, test),
        v.links == 0,
        not MapSet.member?(mounted, v.name),
        not compose?(v[:labels]),
        is_nil(only) or MapSet.member?(only, v.name),
        do: %{kind: :volume, name: v.name, size: v.size}
  end

  @doc false
  # `<test><id><shape>` where id is a plain token: no compose `_`, no
  # workstation `ws-` namespace, no `-home`, only the shapes the suite makes.
  def test_volume?(name, test) do
    with true <- safe_name?(name),
         true <- String.starts_with?(name, test),
         rest = String.replace_prefix(name, test, ""),
         false <- String.starts_with?(rest, "ws-"),
         false <- String.contains?(rest, "_"),
         false <- String.ends_with?(rest, "-home"),
         shape when is_binary(shape) <- Enum.find(@volume_shapes, &String.ends_with?(rest, &1)),
         id = String.replace_suffix(rest, shape, "") do
      id != "" and Regex.match?(~r/\A[a-z0-9][a-z0-9-]*\z/, id)
    else
      _ -> false
    end
  end

  defp mounted_names(containers) do
    containers |> Enum.flat_map(&(&1[:mounts] || [])) |> MapSet.new()
  end

  # ── containers ─────────────────────────────────────────────────────────

  defp containers(containers, prefixes) do
    for c <- containers,
        c.state in @stopped,
        throwaway?(c, prefixes),
        not compose?(c[:labels]),
        do: %{kind: :container, name: c.name, size: c.size}
  end

  @doc false
  # The two throwaways Loopyard names itself, each by its WHOLE shape: the
  # name (`signin-<id>-<n>` from `Workstation.SignIn`, `cp-<n>` from
  # `VolumeIO`) AND the image it runs. A workspace's own containers end in
  # `-work`, `-<service>-<n>` and run other images, so they can't pass.
  def throwaway?(%{name: name, image: image}, prefixes) when is_binary(name) do
    safe_name?(name) and is_binary(image) and
      Enum.any?(prefixes, fn prefix ->
        case String.split_at(name, String.length(prefix)) do
          {^prefix, "signin-" <> tail} ->
            Regex.match?(~r/\A[a-z0-9][a-z0-9-]*-\d+\z/i, tail) and
              String.starts_with?(image, @base_repo <> ":")

          {^prefix, "cp-" <> tail} ->
            Regex.match?(~r/\A\d+\z/, tail) and
              (image == "alpine" or String.starts_with?(image, "alpine:"))

          _ ->
            false
        end
      end)
  end

  def throwaway?(_, _), do: false

  # ── images ─────────────────────────────────────────────────────────────

  defp images(images, containers, opts) do
    current = Keyword.fetch!(opts, :current_image)
    in_use = MapSet.new(containers, & &1[:image])

    images
    |> Enum.filter(&(&1.repository == @base_repo and is_binary(&1.tag)))
    |> Enum.reject(&(&1.tag in ["", "<none>"]))
    |> Enum.map(&Map.put(&1, :ref, "#{&1.repository}:#{&1.tag}"))
    |> Enum.filter(&(&1.ref != current and &1.containers == 0))
    |> Enum.reject(&MapSet.member?(in_use, &1.ref))
    |> Enum.map(&%{kind: :image, name: &1.ref, size: &1.size})
  end

  # ── shared ─────────────────────────────────────────────────────────────

  defp safe_name?(name), do: Regex.match?(~r/\A[a-z0-9][a-z0-9_.-]*\z/i, name)

  defp valid_prefix?(p), do: is_binary(p) and Regex.match?(~r/\A[a-z0-9][a-z0-9-]*-\z/, p)

  defp compose?(labels) when is_binary(labels), do: String.contains?(labels, "com.docker.compose")
  defp compose?(_), do: false

  defp by_size(list), do: Enum.sort_by(list, & &1.size, :desc)

  # ── parsing `docker system df -v --format '{{json .}}'` ────────────────

  @doc """
  Turn `docker system df -v --format '{{json .}}'` output (ONE JSON object
  with Images / Containers / Volumes arrays) into `t:listings/0`.
  """
  @spec from_system_df(String.t()) :: {:ok, listings()} | {:error, String.t()}
  def from_system_df(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{} = df} ->
        {:ok,
         %{
           volumes: Enum.map(df["Volumes"] || [], &volume_row/1),
           containers: Enum.map(df["Containers"] || [], &container_row/1),
           images: Enum.map(df["Images"] || [], &image_row/1)
         }}

      _ ->
        {:error, "unrecognised `docker system df -v` output"}
    end
  end

  defp volume_row(v) do
    %{
      name: v["Name"],
      # An unparseable link count is treated as IN USE — never as dangling.
      links: int(v["Links"], 1),
      size: parse_size(v["Size"]),
      labels: v["Labels"] || ""
    }
  end

  defp container_row(c) do
    %{
      name: c["Names"],
      state: c["State"] || "",
      image: c["Image"] || "",
      mounts: (c["Mounts"] || "") |> String.split(",", trim: true) |> Enum.map(&String.trim/1),
      size: parse_size(c["Size"]),
      labels: c["Labels"] || ""
    }
  end

  defp image_row(i) do
    %{
      repository: i["Repository"],
      tag: i["Tag"],
      # Unknown container count → in use.
      containers: int(i["Containers"], 1),
      size: parse_size(i["UniqueSize"] || i["Size"])
    }
  end

  defp int(n, _fallback) when is_integer(n), do: n

  defp int(s, fallback) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> fallback
    end
  end

  defp int(_, fallback), do: fallback

  @units %{"B" => 1, "kB" => 1_000, "KB" => 1_000, "MB" => 1_000_000, "GB" => 1_000_000_000}
  @units Map.put(@units, "TB", 1_000_000_000_000)

  @doc "Docker's human sizes (`28.72kB`, `1.666GB`, `0B`, `N/A`) to bytes (0 if unknown)."
  def parse_size(s) when is_binary(s) do
    case Regex.run(~r/^\s*([\d.]+)\s*([kKMGT]?B)\s*$/, s) do
      [_, n, unit] ->
        case Float.parse(n) do
          {f, ""} -> round(f * Map.fetch!(@units, unit))
          _ -> 0
        end

      _ ->
        0
    end
  end

  def parse_size(_), do: 0
end
