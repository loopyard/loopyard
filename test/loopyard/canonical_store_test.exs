defmodule Loopyard.CanonicalStoreTest do
  use ExUnit.Case

  alias Loopyard.CanonicalStore

  # The store is a single shared path (<LOOPYARD_HOME>/canonical_projects.json),
  # so save its current content in setup and restore it in on_exit.
  setup do
    path = CanonicalStore.path()
    original = File.read(path)

    on_exit(fn ->
      case original do
        {:ok, content} -> File.write!(path, content)
        _ -> File.rm(path)
      end
    end)

    %{path: path}
  end

  defp unique_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  describe "put/2 and delete/1" do
    test "round-trip through load/0" do
      id = unique_id("proj")
      entry = %{"name" => "demo", "remote" => "git@example.com:demo.git", "workspaces" => %{}}

      assert :ok = CanonicalStore.put(id, entry)
      assert CanonicalStore.load()[id] == entry

      assert :ok = CanonicalStore.delete(id)
      refute Map.has_key?(CanonicalStore.load(), id)
    end

    test "put preserves other entries" do
      id_a = unique_id("proj-a")
      id_b = unique_id("proj-b")

      CanonicalStore.put(id_a, %{"name" => "a"})
      CanonicalStore.put(id_b, %{"name" => "b"})

      loaded = CanonicalStore.load()
      assert loaded[id_a] == %{"name" => "a"}
      assert loaded[id_b] == %{"name" => "b"}
    end
  end

  describe "load/0" do
    test "missing file returns %{}", %{path: path} do
      File.rm(path)
      assert CanonicalStore.load() == %{}
    end

    test "corrupt JSON raises (deliberate — leaves the file intact for recovery)", %{path: path} do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "not json {{{")

      assert_raise RuntimeError, ~r/canonical_projects\.json is corrupt/, fn ->
        CanonicalStore.load()
      end

      # The corrupt file is left in place, not clobbered.
      assert File.read!(path) == "not json {{{"
    end
  end

  describe "write/1" do
    test "is atomic via tmp+rename — no .tmp file left behind", %{path: path} do
      assert :ok = CanonicalStore.write(%{unique_id("proj") => %{"name" => "x"}})

      refute File.exists?(path <> ".tmp")
      assert File.exists?(path)
    end
  end
end
