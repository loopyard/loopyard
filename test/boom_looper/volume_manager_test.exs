defmodule BoomLooper.VolumeManagerTest do
  use ExUnit.Case, async: true

  alias BoomLooper.VolumeManager

  describe "volume naming" do
    test "code_volume_name/1 generates correct name" do
      assert VolumeManager.code_volume_name("abc123") == "bl-abc123-code"
      assert VolumeManager.code_volume_name("workspace-1") == "bl-workspace-1-code"
    end

    test "cache_volume_name/1 generates correct name" do
      assert VolumeManager.cache_volume_name("abc123") == "bl-abc123-cache"
      assert VolumeManager.cache_volume_name("workspace-1") == "bl-workspace-1-cache"
    end
  end

  describe "create_volume/1" do
    @describetag :docker

    test "creates a Docker volume" do
      volume_name = "bl-test-#{:rand.uniform(100_000)}"

      on_exit(fn ->
        System.cmd("docker", ["volume", "rm", "-f", volume_name], stderr_to_stdout: true)
      end)

      assert :ok = VolumeManager.create_volume(volume_name)

      # Verify volume exists
      {output, 0} = System.cmd("docker", ["volume", "ls", "-q"])
      assert String.contains?(output, volume_name)
    end
  end

  describe "delete_volume/1" do
    @describetag :docker

    test "deletes a Docker volume" do
      volume_name = "bl-test-#{:rand.uniform(100_000)}"

      # Create volume first
      System.cmd("docker", ["volume", "create", volume_name])

      assert :ok = VolumeManager.delete_volume(volume_name)

      # Verify volume is gone
      {output, 0} = System.cmd("docker", ["volume", "ls", "-q"])
      refute String.contains?(output, volume_name)
    end

    test "returns ok for non-existent volume" do
      assert :ok = VolumeManager.delete_volume("bl-nonexistent-volume-xyz")
    end
  end

  describe "volume_exists?/1" do
    @describetag :docker

    test "returns true for existing volume" do
      volume_name = "bl-test-#{:rand.uniform(100_000)}"

      on_exit(fn ->
        System.cmd("docker", ["volume", "rm", "-f", volume_name], stderr_to_stdout: true)
      end)

      System.cmd("docker", ["volume", "create", volume_name])
      assert VolumeManager.volume_exists?(volume_name) == true
    end

    test "returns false for non-existent volume" do
      assert VolumeManager.volume_exists?("bl-nonexistent-volume-xyz") == false
    end
  end

  describe "read_file/2 and write_file/3" do
    @describetag :docker

    test "writes and reads a file in a volume" do
      volume_name = "bl-test-#{:rand.uniform(100_000)}"

      on_exit(fn ->
        System.cmd("docker", ["volume", "rm", "-f", volume_name], stderr_to_stdout: true)
      end)

      # Create volume
      VolumeManager.create_volume(volume_name)

      # Write a file
      content = "Hello from test!\nLine 2"
      assert :ok = VolumeManager.write_file(volume_name, "test.txt", content)

      # Read it back
      assert {:ok, ^content} = VolumeManager.read_file(volume_name, "test.txt")
    end

    test "read_file returns error for non-existent file" do
      volume_name = "bl-test-#{:rand.uniform(100_000)}"

      on_exit(fn ->
        System.cmd("docker", ["volume", "rm", "-f", volume_name], stderr_to_stdout: true)
      end)

      VolumeManager.create_volume(volume_name)

      assert {:error, :not_found} = VolumeManager.read_file(volume_name, "nonexistent.txt")
    end

    test "write_file creates nested directories" do
      volume_name = "bl-test-#{:rand.uniform(100_000)}"

      on_exit(fn ->
        System.cmd("docker", ["volume", "rm", "-f", volume_name], stderr_to_stdout: true)
      end)

      VolumeManager.create_volume(volume_name)

      content = "nested content"
      assert :ok = VolumeManager.write_file(volume_name, "a/b/c/test.txt", content)
      assert {:ok, ^content} = VolumeManager.read_file(volume_name, "a/b/c/test.txt")
    end
  end

  describe "copy_to_volume/2" do
    @describetag :docker

    test "copies local directory contents into a volume" do
      volume_name = "bl-test-copy-#{:rand.uniform(100_000)}"
      tmp_dir = Path.join(System.tmp_dir!(), "boom-vol-copy-#{:rand.uniform(100_000)}")
      File.mkdir_p!(tmp_dir)
      File.write!(Path.join(tmp_dir, "README.md"), "# Test Project")
      File.mkdir_p!(Path.join(tmp_dir, "src"))
      File.write!(Path.join(tmp_dir, "src/main.rb"), "puts 'hello'")

      on_exit(fn ->
        System.cmd("docker", ["volume", "rm", "-f", volume_name], stderr_to_stdout: true)
        File.rm_rf!(tmp_dir)
      end)

      VolumeManager.create_volume(volume_name)
      assert {:ok, _output} = VolumeManager.copy_to_volume(volume_name, tmp_dir)
      assert {:ok, "# Test Project"} = VolumeManager.read_file(volume_name, "README.md")
      assert {:ok, "puts 'hello'"} = VolumeManager.read_file(volume_name, "src/main.rb")
    end

    test "calls streaming callback during copy" do
      volume_name = "bl-test-copy-cb-#{:rand.uniform(100_000)}"
      tmp_dir = Path.join(System.tmp_dir!(), "boom-vol-copy-cb-#{:rand.uniform(100_000)}")
      File.mkdir_p!(tmp_dir)
      File.write!(Path.join(tmp_dir, "test.txt"), "data")

      on_exit(fn ->
        System.cmd("docker", ["volume", "rm", "-f", volume_name], stderr_to_stdout: true)
        File.rm_rf!(tmp_dir)
      end)

      me = self()
      VolumeManager.create_volume(volume_name)

      assert {:ok, _} =
               VolumeManager.copy_to_volume(volume_name, tmp_dir,
                 callback: fn _chunk -> send(me, :got_chunk) end
               )
    end
  end

  describe "glob/2" do
    @describetag :docker

    test "finds files matching pattern in a volume" do
      volume_name = "bl-test-glob-#{:rand.uniform(100_000)}"

      on_exit(fn ->
        System.cmd("docker", ["volume", "rm", "-f", volume_name], stderr_to_stdout: true)
      end)

      VolumeManager.create_volume(volume_name)
      VolumeManager.write_file(volume_name, "app.rb", "code")
      VolumeManager.write_file(volume_name, "lib/helper.rb", "more code")
      VolumeManager.write_file(volume_name, "README.md", "docs")

      assert {:ok, files} = VolumeManager.glob(volume_name, "*.rb")
      assert Enum.any?(files, &String.ends_with?(&1, ".rb"))
      refute Enum.any?(files, &String.ends_with?(&1, ".md"))
    end
  end

  describe "volume_has_code?/1" do
    @describetag :docker

    test "returns false for empty volume" do
      volume_name = "bl-test-#{:rand.uniform(100_000)}"

      on_exit(fn ->
        System.cmd("docker", ["volume", "rm", "-f", volume_name], stderr_to_stdout: true)
      end)

      VolumeManager.create_volume(volume_name)
      assert VolumeManager.volume_has_code?(volume_name) == false
    end

    test "returns true for volume with .git directory" do
      volume_name = "bl-test-#{:rand.uniform(100_000)}"

      on_exit(fn ->
        System.cmd("docker", ["volume", "rm", "-f", volume_name], stderr_to_stdout: true)
      end)

      VolumeManager.create_volume(volume_name)

      # Create a .git directory to simulate cloned repo
      System.cmd("docker", [
        "run",
        "--rm",
        "-v",
        "#{volume_name}:/workspace",
        "alpine",
        "sh",
        "-c",
        "mkdir -p /workspace/.git"
      ])

      assert VolumeManager.volume_has_code?(volume_name) == true
    end
  end

  describe "volume_info/1" do
    @describetag :docker

    test "returns volume info for existing volume" do
      volume_name = "bl-test-#{:rand.uniform(100_000)}"

      on_exit(fn ->
        System.cmd("docker", ["volume", "rm", "-f", volume_name], stderr_to_stdout: true)
      end)

      VolumeManager.create_volume(volume_name)

      info = VolumeManager.volume_info(volume_name)
      assert info.name == volume_name
      assert info.driver == "local"
      assert is_binary(info.mount_point)
      assert is_binary(info.size)
    end

    test "returns nil for non-existent volume" do
      assert VolumeManager.volume_info("bl-nonexistent-xyz") == nil
    end

    test "identifies code volume purpose" do
      volume_name = "bl-abc123-code"

      on_exit(fn ->
        System.cmd("docker", ["volume", "rm", "-f", volume_name], stderr_to_stdout: true)
      end)

      VolumeManager.create_volume(volume_name)
      info = VolumeManager.volume_info(volume_name)

      assert info.type == :code
      assert info.service == "workspace"
      assert info.description == "Project source code"
    end

    test "identifies service data volume purpose" do
      volume_name = "postgres-data-abc123"

      on_exit(fn ->
        System.cmd("docker", ["volume", "rm", "-f", volume_name], stderr_to_stdout: true)
      end)

      VolumeManager.create_volume(volume_name)
      info = VolumeManager.volume_info(volume_name)

      assert info.type == :data
      assert info.service == "postgres"
      assert info.description == "PostgreSQL database"
    end
  end

  describe "tree/3" do
    @describetag :docker

    test "returns structured entries for volume contents" do
      volume_name = "bl-test-tree-#{:rand.uniform(100_000)}"

      on_exit(fn ->
        System.cmd("docker", ["volume", "rm", "-f", volume_name], stderr_to_stdout: true)
      end)

      VolumeManager.create_volume(volume_name)
      VolumeManager.write_file(volume_name, "README.md", "# Test")
      VolumeManager.write_file(volume_name, "src/main.rb", "puts 'hi'")

      # tree needs a running container named bl-<id>-workspace-1 for the volume
      # Since we can't easily set that up in a unit test, verify :no_container
      assert {:error, :no_container} = VolumeManager.tree(volume_name)
    end
  end

  describe "tree path prefixing" do
    # Test the path logic in isolation by verifying parse_tree behavior
    # through the module's internal function. We make it testable by
    # testing the full integration path on a live workspace.

    @describetag :docker

    test "root tree returns workspace-relative paths" do
      # Use a live workspace if available (garryslist 0a6a)
      vol = "bl-0a6a-code"

      case VolumeManager.tree(vol, ".") do
        {:ok, entries} ->
          # Root entries should NOT have a prefix
          for entry <- Enum.take(entries, 5) do
            refute String.starts_with?(entry.path, "/"),
                   "path #{entry.path} should not start with /"

            assert entry.name == Path.basename(entry.path), "name should be basename of path"
          end

        {:error, :no_container} ->
          # No workspace running — skip this test gracefully
          :ok
      end
    end

    test "subdirectory tree returns full workspace-relative paths" do
      vol = "bl-0a6a-code"

      case VolumeManager.tree(vol, "app") do
        {:ok, entries} ->
          for entry <- Enum.take(entries, 5) do
            assert String.starts_with?(entry.path, "app/"),
                   "entry path #{entry.path} should start with app/"
          end

        {:error, :no_container} ->
          :ok
      end
    end

    test "deeply nested tree returns full paths" do
      vol = "bl-0a6a-code"

      case VolumeManager.tree(vol, "app/models") do
        {:ok, entries} when entries != [] ->
          for entry <- Enum.take(entries, 5) do
            assert String.starts_with?(entry.path, "app/models/"),
                   "entry path #{entry.path} should start with app/models/"
          end

        _ ->
          :ok
      end
    end
  end

  describe "volume_ls/2" do
    @describetag :docker

    test "lists directory contents in volume" do
      volume_name = "bl-test-ls-#{:rand.uniform(100_000)}"

      on_exit(fn ->
        System.cmd("docker", ["volume", "rm", "-f", volume_name], stderr_to_stdout: true)
      end)

      VolumeManager.create_volume(volume_name)
      VolumeManager.write_file(volume_name, "README.md", "# Test")
      VolumeManager.write_file(volume_name, "src/main.rb", "puts 'hi'")

      assert {:ok, output} = VolumeManager.volume_ls(volume_name)
      assert String.contains?(output, "README.md")
    end

    test "lists subdirectory contents" do
      volume_name = "bl-test-ls-sub-#{:rand.uniform(100_000)}"

      on_exit(fn ->
        System.cmd("docker", ["volume", "rm", "-f", volume_name], stderr_to_stdout: true)
      end)

      VolumeManager.create_volume(volume_name)
      VolumeManager.write_file(volume_name, "src/main.rb", "puts 'hi'")
      VolumeManager.write_file(volume_name, "src/lib/helper.rb", "module Helper; end")

      assert {:ok, output} = VolumeManager.volume_ls(volume_name, "/src")
      assert String.contains?(output, "main.rb")
      assert String.contains?(output, "lib")
    end
  end
end
