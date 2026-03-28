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
        "run", "--rm",
        "-v", "#{volume_name}:/workspace",
        "alpine", "sh", "-c", "mkdir -p /workspace/.git"
      ])

      assert VolumeManager.volume_has_code?(volume_name) == true
    end
  end
end
