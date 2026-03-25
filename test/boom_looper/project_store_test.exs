defmodule BoomLooper.ProjectStoreTest do
  use ExUnit.Case, async: true

  alias BoomLooper.ProjectStore

  setup do
    # Use a temp directory for BOOMLOOPER_HOME
    tmp_dir = Path.join(System.tmp_dir!(), "project_store_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    # Set env var for this test
    original_home = System.get_env("BOOMLOOPER_HOME")
    System.put_env("BOOMLOOPER_HOME", tmp_dir)

    on_exit(fn ->
      # Restore original env
      if original_home do
        System.put_env("BOOMLOOPER_HOME", original_home)
      else
        System.delete_env("BOOMLOOPER_HOME")
      end
      File.rm_rf!(tmp_dir)
    end)

    %{tmp_dir: tmp_dir}
  end

  describe "load/0" do
    test "returns empty list when file doesn't exist" do
      assert ProjectStore.load() == []
    end

    test "returns empty list for invalid JSON" do
      File.write!(ProjectStore.path(), "not json")
      assert ProjectStore.load() == []
    end

    test "returns empty list for JSON without projects key" do
      File.write!(ProjectStore.path(), Jason.encode!(%{"other" => "data"}))
      assert ProjectStore.load() == []
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

      assert ProjectStore.load() == ["/path/to/project1", "/path/to/project2"]
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

      assert ProjectStore.load() == ["/valid/path", "/another/valid"]
    end
  end

  describe "save/1" do
    test "creates file with project records" do
      ProjectStore.save(["/path/one", "/path/two"])

      assert File.exists?(ProjectStore.path())

      {:ok, content} = File.read(ProjectStore.path())
      data = Jason.decode!(content)

      assert data["version"] == 1
      assert data["projects"] == [
        %{"path" => "/path/one"},
        %{"path" => "/path/two"}
      ]
    end

    test "creates parent directories", %{tmp_dir: tmp_dir} do
      # Use a nested path that doesn't exist yet
      nested_home = Path.join(tmp_dir, "nested/deeper")
      System.put_env("BOOMLOOPER_HOME", nested_home)

      refute File.exists?(nested_home)

      ProjectStore.save(["/some/path"])

      assert File.exists?(ProjectStore.path())

      # Restore for other tests
      System.put_env("BOOMLOOPER_HOME", tmp_dir)
    end

    test "overwrites existing file" do
      ProjectStore.save(["/old/path"])
      ProjectStore.save(["/new/path"])

      assert ProjectStore.load() == ["/new/path"]
    end
  end

  describe "add/1" do
    test "creates file and adds path" do
      assert :ok = ProjectStore.add("/my/project")
      assert ProjectStore.load() == ["/my/project"]
    end

    test "appends to existing paths" do
      ProjectStore.add("/first")
      ProjectStore.add("/second")

      assert ProjectStore.load() == ["/first", "/second"]
    end

    test "is idempotent - no duplicates" do
      ProjectStore.add("/same/path")
      ProjectStore.add("/same/path")
      ProjectStore.add("/same/path")

      assert ProjectStore.load() == ["/same/path"]
    end

    test "preserves existing paths when adding new" do
      ProjectStore.add("/existing")
      ProjectStore.add("/new")

      assert ProjectStore.load() == ["/existing", "/new"]
    end
  end

  describe "remove/1" do
    test "removes path from file" do
      ProjectStore.add("/keep")
      ProjectStore.add("/remove")
      ProjectStore.add("/also-keep")

      ProjectStore.remove("/remove")

      assert ProjectStore.load() == ["/keep", "/also-keep"]
    end

    test "handles removing non-existent path" do
      ProjectStore.add("/exists")
      ProjectStore.remove("/does-not-exist")

      assert ProjectStore.load() == ["/exists"]
    end

    test "handles removing from empty file" do
      assert :ok = ProjectStore.remove("/anything")
      assert ProjectStore.load() == []
    end
  end

  describe "path/0" do
    test "uses BOOMLOOPER_HOME env var", %{tmp_dir: tmp_dir} do
      assert ProjectStore.path() == Path.join(tmp_dir, "projects.json")
    end
  end
end
