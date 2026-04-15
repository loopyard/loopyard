defmodule BoomLooperWeb.Live.WorkspaceLive.FileBrowserTest do
  use ExUnit.Case, async: true

  alias BoomLooperWeb.Live.WorkspaceLive.FileBrowser

  # probe_path/2 is the interesting pure function — it decides whether
  # a volume path is a file, a directory, or missing. The LiveView's
  # handle_async dispatches on the returned shape, so drift between
  # probe_path's output and the LV's pattern match would silently
  # break the file viewer. These tests lock the shape.

  describe "probe_path/2 return shape" do
    test "probe_path/2 exists and accepts (volume_name, path)" do
      # Smoke test: probe a volume that doesn't exist — VolumeIO will
      # error, VolumeManager.tree will error, we should get the
      # not_found shape without crashing.
      result = FileBrowser.probe_path("bl-does-not-exist-probe", "some/file")

      assert %{path: "some/file", not_found: true, content: nil} = result
    end
  end
end
