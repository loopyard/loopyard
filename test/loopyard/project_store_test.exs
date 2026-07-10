defmodule Loopyard.ProjectStoreTest do
  # async: false — this test mutates the global LOOPYARD_HOME env var
  # via System.put_env/2 in setup. Concurrent tests would clobber each
  # other's value (it's process-global, not per-test). Lock to serial.
  use ExUnit.Case, async: false

  alias Loopyard.ProjectStore

  setup do
    # Use a temp directory for LOOPYARD_HOME
    tmp_dir =
      Path.join(System.tmp_dir!(), "project_store_test_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    # Set env var for this test
    original_home = System.get_env("LOOPYARD_HOME")
    System.put_env("LOOPYARD_HOME", tmp_dir)

    on_exit(fn ->
      # Restore original env
      if original_home do
        System.put_env("LOOPYARD_HOME", original_home)
      else
        System.delete_env("LOOPYARD_HOME")
      end

      File.rm_rf(tmp_dir)
    end)

    %{tmp_dir: tmp_dir}
  end

  describe "load/0" do
    test "returns empty list when file doesn't exist" do
      assert ProjectStore.load() == []
    end

    test "raises for invalid JSON (so the corrupt file isn't overwritten empty)" do
      # #39: load/0 raises on a corrupt (non-enoent) file rather than returning
      # []. The boot restore is wrapped in safe_restore, so this leaves the
      # on-disk file intact for recovery instead of letting a later empty
      # save/1 turn a recoverable corruption into permanent registry loss.
      File.write!(ProjectStore.path(), "not json")
      assert_raise RuntimeError, ~r/corrupt/, fn -> ProjectStore.load() end
    end

    test "raises for JSON without projects key" do
      File.write!(ProjectStore.path(), Jason.encode!(%{"other" => "data"}))
      assert_raise RuntimeError, ~r/corrupt/, fn -> ProjectStore.load() end
    end

    test "returns paths from valid file" do
      data = %{
        "version" => 1,
        "projects" => [
          %{"path" => "/path/to/project1"},
          %{"path" => "/path/to/project2"}
        ]
      }

      File.mkdir_p!(Path.dirname(ProjectStore.path()))
      File.write!(ProjectStore.path(), Jason.encode!(data))

      loaded = ProjectStore.load()
      assert Enum.map(loaded, & &1.path) == ["/path/to/project1", "/path/to/project2"]
      assert Enum.all?(loaded, &(&1.name == nil))
      # Legacy records are migrated inline — paths infer as :local.
      assert Enum.all?(loaded, &(&1.source_type == :local))
    end

    test "ignores records without path key" do
      data = %{
        "version" => 1,
        "projects" => [
          %{"path" => "/valid/path"},
          %{"other" => "no path here"},
          %{"path" => "/another/valid"}
        ]
      }

      File.mkdir_p!(Path.dirname(ProjectStore.path()))
      File.write!(ProjectStore.path(), Jason.encode!(data))

      loaded = ProjectStore.load()
      assert Enum.map(loaded, & &1.path) == ["/valid/path", "/another/valid"]
    end

    test "infers github source_type from git URLs" do
      data = %{
        "version" => 2,
        "projects" => [
          %{"path" => "git@github.com:owner/repo.git"},
          %{"path" => "https://github.com/owner/repo.git"}
        ]
      }

      File.mkdir_p!(Path.dirname(ProjectStore.path()))
      File.write!(ProjectStore.path(), Jason.encode!(data))

      loaded = ProjectStore.load()
      assert Enum.all?(loaded, &(&1.source_type == :github))
    end

    test "honors explicit source_type in the file" do
      data = %{
        "version" => 2,
        "projects" => [
          %{"path" => "/any/path", "source_type" => "github"}
        ]
      }

      File.mkdir_p!(Path.dirname(ProjectStore.path()))
      File.write!(ProjectStore.path(), Jason.encode!(data))

      assert [%{source_type: :github}] = ProjectStore.load()
    end
  end

  describe "save/1" do
    test "creates file with project records" do
      ProjectStore.save(["/path/one", "/path/two"])

      assert File.exists?(ProjectStore.path())

      {:ok, content} = File.read(ProjectStore.path())
      data = Jason.decode!(content)

      assert data["version"] == 2
      paths = Enum.map(data["projects"], & &1["path"])
      assert paths == ["/path/one", "/path/two"]
      types = Enum.map(data["projects"], & &1["source_type"])
      assert types == ["local", "local"]
    end

    test "creates parent directories", %{tmp_dir: tmp_dir} do
      # Use a nested path that doesn't exist yet
      nested_home = Path.join(tmp_dir, "nested/deeper")
      System.put_env("LOOPYARD_HOME", nested_home)

      refute File.exists?(nested_home)

      ProjectStore.save(["/some/path"])

      assert File.exists?(ProjectStore.path())

      # Restore for other tests
      System.put_env("LOOPYARD_HOME", tmp_dir)
    end

    test "overwrites existing file" do
      ProjectStore.save(["/old/path"])
      ProjectStore.save(["/new/path"])

      assert [%{path: "/new/path", name: nil}] = ProjectStore.load()
    end
  end

  describe "add/1" do
    test "creates file and adds path" do
      assert :ok = ProjectStore.add("/my/project")
      assert [%{path: "/my/project", name: nil, source_type: :local}] = ProjectStore.load()
    end

    test "accepts explicit source_type" do
      assert :ok = ProjectStore.add("/my/project", source_type: :local)
      assert [%{source_type: :local}] = ProjectStore.load()
    end

    test "appends to existing paths" do
      ProjectStore.add("/first")
      ProjectStore.add("/second")

      paths = ProjectStore.load() |> Enum.map(& &1.path)
      assert paths == ["/first", "/second"]
    end

    test "is idempotent - no duplicates" do
      ProjectStore.add("/same/path")
      ProjectStore.add("/same/path")
      ProjectStore.add("/same/path")

      assert [%{path: "/same/path"}] = ProjectStore.load()
    end

    test "preserves existing paths when adding new" do
      ProjectStore.add("/existing")
      ProjectStore.add("/new")

      paths = ProjectStore.load() |> Enum.map(& &1.path)
      assert paths == ["/existing", "/new"]
    end
  end

  describe "remove/1" do
    test "removes path from file" do
      ProjectStore.add("/keep")
      ProjectStore.add("/remove")
      ProjectStore.add("/also-keep")

      ProjectStore.remove("/remove")

      paths = ProjectStore.load() |> Enum.map(& &1.path)
      assert paths == ["/keep", "/also-keep"]
    end

    test "handles removing non-existent path" do
      ProjectStore.add("/exists")
      ProjectStore.remove("/does-not-exist")

      assert [%{path: "/exists"}] = ProjectStore.load()
    end

    test "handles removing from empty file" do
      assert :ok = ProjectStore.remove("/anything")
      assert ProjectStore.load() == []
    end
  end

  describe "path/0" do
    test "uses LOOPYARD_HOME env var", %{tmp_dir: tmp_dir} do
      assert ProjectStore.path() == Path.join(tmp_dir, "projects.json")
    end
  end
end
