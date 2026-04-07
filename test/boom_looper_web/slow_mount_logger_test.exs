defmodule BoomLooperWeb.SlowMountLoggerTest do
  use ExUnit.Case, async: false

  alias BoomLooperWeb.SlowMountLogger

  import ExUnit.CaptureLog

  describe "handle_event/4" do
    test "logs a warning when duration exceeds the threshold" do
      duration_native =
        System.convert_time_unit(SlowMountLogger.threshold_us() + 1_000, :microsecond, :native)

      log =
        capture_log(fn ->
          SlowMountLogger.handle_event(
            [:phoenix, :live_view, :mount, :stop],
            %{duration: duration_native},
            %{socket: %{view: BoomLooperWeb.SystemLive}},
            nil
          )
        end)

      assert log =~ "[SlowMount]"
      assert log =~ "SystemLive"
      assert log =~ "mount"
      assert log =~ "ms"
    end

    test "does NOT log when duration is under the threshold" do
      duration_native =
        System.convert_time_unit(div(SlowMountLogger.threshold_us(), 2), :microsecond, :native)

      log =
        capture_log(fn ->
          SlowMountLogger.handle_event(
            [:phoenix, :live_view, :mount, :stop],
            %{duration: duration_native},
            %{socket: %{view: BoomLooperWeb.SystemLive}},
            nil
          )
        end)

      refute log =~ "[SlowMount]"
    end

    test "logs handle_params slowness too" do
      duration_native =
        System.convert_time_unit(SlowMountLogger.threshold_us() + 1, :microsecond, :native)

      log =
        capture_log(fn ->
          SlowMountLogger.handle_event(
            [:phoenix, :live_view, :handle_params, :stop],
            %{duration: duration_native},
            %{socket: %{view: BoomLooperWeb.ChatLive}},
            nil
          )
        end)

      assert log =~ "handle_params"
      assert log =~ "ChatLive"
    end
  end

  describe "attach/0 + detach/0" do
    test "attaches and detaches without raising" do
      # Detach first in case the application's start/0 already attached.
      SlowMountLogger.detach()
      assert :ok = SlowMountLogger.attach()
      assert :ok = SlowMountLogger.detach()
      # Re-attach so the global state matches what application start expects.
      SlowMountLogger.attach()
    end
  end
end
