defmodule Loopyard.VolumeIOTest do
  use ExUnit.Case

  alias Loopyard.VolumeIO

  # Path validation happens BEFORE any container/Docker interaction, so these
  # cases run without the :docker tag. They pin the #36 fix: a path that
  # escapes /workspace or carries a null byte is rejected up front (and never
  # shell-interpolated into a docker command).
  describe "path validation (no Docker)" do
    test "rejects parent-directory traversal that escapes /workspace" do
      assert {:error, :invalid_path} = VolumeIO.read_file("loopyard-x-code", "../etc/passwd")
      assert {:error, :invalid_path} = VolumeIO.read_file("loopyard-x-code", "a/../../etc/shadow")
      assert {:error, :invalid_path} = VolumeIO.write_file("loopyard-x-code", "../escape", "x")
    end

    test "rejects absolute paths outside /workspace" do
      assert {:error, :invalid_path} = VolumeIO.read_file("loopyard-x-code", "/etc/passwd")
    end

    test "rejects null bytes" do
      assert {:error, :invalid_path} = VolumeIO.read_file("loopyard-x-code", "a\0b")
      assert {:error, :invalid_path} = VolumeIO.write_file("loopyard-x-code", "a\0b", "x")
    end

    test "rejects non-binary paths" do
      assert {:error, :invalid_path} = VolumeIO.read_file("loopyard-x-code", :not_a_string)
    end
  end

  describe "copy_in/3 validation (no Docker)" do
    test "rejects a destination outside /workspace and a missing host file" do
      assert {:error, :invalid_path} = VolumeIO.copy_in("loopyard-x-code", __ENV__.file, "../x")
      assert {:error, :enoent} = VolumeIO.copy_in("loopyard-x-code", "/nope/missing.png", "a.png")
    end
  end

  describe "read_file/2" do
    @describetag :docker
    setup :create_test_volume

    test "reads a file from a volume", %{volume: volume} do
      # Write a file first
      :ok = VolumeIO.write_file(volume, "hello.txt", "world")
      assert {:ok, "world"} = VolumeIO.read_file(volume, "hello.txt")
    end

    test "returns error for missing file", %{volume: volume} do
      assert {:error, _} = VolumeIO.read_file(volume, "nonexistent.txt")
    end
  end

  describe "write_file/3" do
    @describetag :docker
    setup :create_test_volume

    test "writes and reads back content", %{volume: volume} do
      content = "line 1\nline 2\nline 3"
      :ok = VolumeIO.write_file(volume, "test.txt", content)
      assert {:ok, ^content} = VolumeIO.read_file(volume, "test.txt")
    end

    test "creates intermediate directories", %{volume: volume} do
      :ok = VolumeIO.write_file(volume, "deep/nested/dir/file.txt", "nested!")
      assert {:ok, "nested!"} = VolumeIO.read_file(volume, "deep/nested/dir/file.txt")
    end

    test "overwrites existing file", %{volume: volume} do
      :ok = VolumeIO.write_file(volume, "overwrite.txt", "first")
      :ok = VolumeIO.write_file(volume, "overwrite.txt", "second")
      assert {:ok, "second"} = VolumeIO.read_file(volume, "overwrite.txt")
    end
  end

  describe "copy_in/3" do
    @describetag :docker
    setup :create_test_volume

    test "streams a binary host file into the volume, creating the directory", %{volume: volume} do
      # Bigger than the ~128KB per-argument limit that caps write_file/3, and
      # binary (a PNG-ish header + noise) — the two things copy_in exists for.
      bytes = <<137, 80, 78, 71, 13, 10, 26, 10>> <> :crypto.strong_rand_bytes(300_000)
      host = Path.join(System.tmp_dir!(), "copy-in-#{System.unique_integer([:positive])}.png")
      File.write!(host, bytes)
      on_exit(fn -> File.rm(host) end)

      assert :ok = VolumeIO.copy_in(volume, host, ".loopyard/uploads/shot.png")
      assert {:ok, ^bytes} = VolumeIO.read_file(volume, ".loopyard/uploads/shot.png")
    end
  end

  # --- Test helpers ---

  defp create_test_volume(_context) do
    volume = "test-volume-io-#{:rand.uniform(100_000)}"
    Loopyard.Docker.docker(["volume", "create", volume])

    on_exit(fn ->
      Loopyard.Docker.docker(["volume", "rm", "-f", volume])
    end)

    %{volume: volume}
  end
end
