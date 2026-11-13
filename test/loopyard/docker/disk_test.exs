defmodule Loopyard.Docker.DiskTest do
  use ExUnit.Case, async: true

  alias Loopyard.Docker.Disk

  @gb 1_000_000_000

  describe "parse_df/1" do
    test "busybox df -P (the real shape from the full Colima VM)" do
      out = """
      Filesystem           1024-blocks    Used Available Capacity Mounted on
      overlay              100476656 100292084    168188 100% /
      """

      assert Disk.parse_df(out) ==
               {:ok, %{free_bytes: 168_188 * 1024, total_bytes: 100_476_656 * 1024}}
    end

    test "GNU df -Pk, and a 512-block header" do
      gnu = """
      Filesystem     1024-blocks     Used Available Capacity Mounted on
      /dev/vda1        51290592 20123456  31167136      40% /
      """

      assert {:ok, %{free_bytes: 31_915_147_264}} = Disk.parse_df(gnu)

      bsd = """
      Filesystem 512-blocks Used Available Capacity Mounted on
      /dev/disk3 1000 400 600 40% /
      """

      assert Disk.parse_df(bsd) == {:ok, %{free_bytes: 600 * 512, total_bytes: 1000 * 512}}
    end

    test "a filesystem or mount name with spaces doesn't shift the columns" do
      out = """
      Filesystem 1024-blocks Used Available Capacity Mounted on
      my fs name 2000 500 1500 25% /mnt/with space
      """

      assert Disk.parse_df(out) == {:ok, %{free_bytes: 1500 * 1024, total_bytes: 2000 * 1024}}
    end

    test "garbage is an error, never a reading" do
      for out <- ["", "OCI runtime exec failed", "Filesystem\n", "a b c\nx y z 10% /", nil] do
        assert {:error, _} = Disk.parse_df(out), "parsed #{inspect(out)}"
      end
    end
  end

  test "full_error?/1 recognises ENOSPC in Docker's wording, and nothing else" do
    assert Disk.full_error?(
             "OCI runtime exec failed: write /tmp/runc-process: no space left on device: unknown"
           )

    assert Disk.full_error?("Error: ENOSPC: no space left on device, write")
    assert Disk.full_error?("NO SPACE LEFT ON DEVICE")
    refute Disk.full_error?("Error response from daemon: container is not running")
    refute Disk.full_error?("spacecraft left the device")
    refute Disk.full_error?(nil)
  end

  describe "status/2" do
    @opts [degraded_bytes: 5 * @gb, down_bytes: div(@gb, 2)]

    test "no reading yet is healthy; a plentiful disk is healthy" do
      assert Disk.status(nil) == :healthy
      assert Disk.status(%{free_bytes: 50 * @gb, total_bytes: 100 * @gb}, @opts) == :healthy
    end

    test "below the threshold is degraded, with the free figure in the reason" do
      assert {:degraded, reason} =
               Disk.status(%{free_bytes: 4 * @gb, total_bytes: 96 * @gb}, @opts)

      assert reason =~ "4.0 GB free of 96 GB"
    end

    test "below the floor, or once a write failed, is down" do
      assert {:down, reason} =
               Disk.status(%{free_bytes: 165_000_000, total_bytes: 96 * @gb}, @opts)

      assert reason =~ "165 MB free"
      assert {:down, reason} = Disk.status(:full)
      assert reason =~ "no space left on device"
    end
  end

  test "human_bytes/1" do
    assert Disk.human_bytes(0) == "0 B"
    assert Disk.human_bytes(29_390) == "29 kB"
    assert Disk.human_bytes(165_000_000) == "165 MB"
    assert Disk.human_bytes(4_200_000_000) == "4.2 GB"
    assert Disk.human_bytes(103_000_000_000) == "103 GB"
  end

  test "alert_item/2 is ONE id, names the cause and the action, belongs to no agent" do
    item = Disk.alert_item(:down, {:down, "165 MB free of 96 GB"})
    assert item.id == Disk.alert_id()
    assert item.kind == :alert
    assert item.agent_id == "loopyard"
    assert item.path == "/system"
    assert item.label =~ "full"
    assert item.label =~ "165 MB free"
    assert item.meta.action =~ "mix loopyard.gc"
    assert Disk.alert_item(:degraded, {:degraded, "x"}).id == item.id
  end
end
