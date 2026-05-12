defmodule Loopyard.VolumeIOTest do
  use ExUnit.Case

  alias Loopyard.VolumeIO

  # These tests need Docker to run containers
  @moduletag :docker

  describe "read_file/2" do
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
