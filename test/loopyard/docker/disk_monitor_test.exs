defmodule Loopyard.Docker.DiskMonitorTest do
  @moduledoc """
  The disk monitor drives the /system row and the ONE inbox item: raised when
  the disk crosses into degraded or down, updated as it worsens, settled when
  space recovers — and never a line in any agent's chat.
  """
  use ExUnit.Case, async: false

  alias Loopyard.Docker.{Disk, DiskMonitor}
  alias Loopyard.{Health, Notifications}
  import Loopyard.TestHelpers, only: [eventually: 1]

  @gb 1_000_000_000

  setup do
    on_exit(fn ->
      # Leave the singleton healthy and the store clean for the next module.
      probe_with({:ok, %{free_bytes: 500 * @gb, total_bytes: 1000 * @gb}})
      Application.delete_env(:loopyard, :docker_disk_probe_fun)
      Notifications.sync()
      :ets.delete(:notifications, Disk.alert_id())
    end)

    probe_with({:ok, %{free_bytes: 500 * @gb, total_bytes: 1000 * @gb}})
    :ets.delete(:notifications, Disk.alert_id())
    :ok
  end

  defp probe_with(result) do
    Application.put_env(:loopyard, :docker_disk_probe_fun, fn -> result end)
    DiskMonitor.probe_now()
    expected = result |> obs() |> Disk.status()
    eventually(fn -> DiskMonitor.status() == expected end)
    Notifications.sync()
  end

  defp obs({:ok, r}), do: r
  defp obs(:full), do: :full

  test "a healthy disk is a healthy /system row and nothing in the inbox" do
    assert Health.component(:docker_disk) == :healthy
    assert :docker_disk in Health.components()
    assert Notifications.get(Disk.alert_id()) == nil
  end

  test "degraded raises ONE item; worse updates it; recovery settles it" do
    probe_with({:ok, %{free_bytes: 2 * @gb, total_bytes: 96 * @gb}})

    assert {:degraded, reason} = Health.component(:docker_disk)
    assert reason =~ "2.0 GB free of 96 GB"
    assert %{status: :open, kind: :alert, label: label} = Notifications.get(Disk.alert_id())
    assert label =~ "nearly full"
    assert Enum.count(Notifications.open(), &(&1.id == Disk.alert_id())) == 1

    probe_with({:ok, %{free_bytes: 100_000_000, total_bytes: 96 * @gb}})
    assert {:down, _} = Health.component(:docker_disk)
    assert %{status: :open, label: label} = Notifications.get(Disk.alert_id())
    assert label =~ "100 MB free"
    assert Enum.count(Notifications.open(), &(&1.id == Disk.alert_id())) == 1

    probe_with({:ok, %{free_bytes: 50 * @gb, total_bytes: 96 * @gb}})
    assert Health.component(:docker_disk) == :healthy
    assert %{status: :settled, outcome: :recovered} = Notifications.get(Disk.alert_id())
  end

  test "the same level again does not re-raise a dismissed item" do
    probe_with({:ok, %{free_bytes: 2 * @gb, total_bytes: 96 * @gb}})
    Notifications.dismiss(Disk.alert_id())
    Notifications.sync()

    probe_with({:ok, %{free_bytes: 1 * @gb, total_bytes: 96 * @gb}})
    assert %{status: :dismissed} = Notifications.get(Disk.alert_id())
  end

  test "report_full/1 (an exec that hit ENOSPC) is down at once" do
    DiskMonitor.report_full("no space left on device")
    DiskMonitor.sync()
    Notifications.sync()

    assert {:down, reason} = Health.component(:docker_disk)
    assert reason =~ "full"
    assert %{status: :open, label: label} = Notifications.get(Disk.alert_id())
    assert label =~ "Agents can't run"
  end

  test "a probe that failed for another reason keeps the last verdict" do
    probe_with({:ok, %{free_bytes: 2 * @gb, total_bytes: 96 * @gb}})
    Application.put_env(:loopyard, :docker_disk_probe_fun, fn -> {:error, "daemon hiccup"} end)
    DiskMonitor.probe_now()
    DiskMonitor.sync()
    assert {:degraded, _} = DiskMonitor.status()
    assert %{status: :open} = Notifications.get(Disk.alert_id())
  end

  test "a raising probe never takes the monitor down" do
    Application.put_env(:loopyard, :docker_disk_probe_fun, fn -> raise "boom" end)
    pid = Process.whereis(DiskMonitor)
    DiskMonitor.probe_now()
    DiskMonitor.sync()
    assert Process.whereis(DiskMonitor) == pid
    assert DiskMonitor.status() == :healthy
  end

  test "the real probe is skipped while the daemon gate is closed (test env)" do
    assert DiskMonitor.probe() == :skipped
  end

  test "thresholds come from config" do
    Application.put_env(:loopyard, :docker_disk_degraded_free_bytes, 600 * @gb)
    on_exit(fn -> Application.delete_env(:loopyard, :docker_disk_degraded_free_bytes) end)
    assert {:degraded, _} = Disk.status(%{free_bytes: 500 * @gb, total_bytes: 1000 * @gb})
  end
end
