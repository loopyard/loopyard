defmodule Loopyard.WindowViewsTest do
  use ExUnit.Case, async: false

  alias Loopyard.WindowViews

  setup do
    Loopyard.StateKeeper.ensure_tables!()
    :ets.delete_all_objects(:window_views)
    :ok
  end

  test "resume_path is nil until a view is touched" do
    assert WindowViews.resume_path(self(), "ws-a") == nil
  end

  test "touch records the last view for a (connection, workspace)" do
    WindowViews.touch(self(), "ws-a", "/projects/p/workspaces/ws-a/services/dev")
    assert WindowViews.resume_path(self(), "ws-a") == "/projects/p/workspaces/ws-a/services/dev"
  end

  test "two windows (connections) are isolated — the multi-window scenario" do
    win1 = spawn(fn -> :ok end)
    win2 = spawn(fn -> :ok end)

    WindowViews.touch(win1, "ws-a", "/win1-view-of-a")
    WindowViews.touch(win2, "ws-a", "/win2-view-of-a")

    # Same workspace, different windows — no clobbering.
    assert WindowViews.resume_path(win1, "ws-a") == "/win1-view-of-a"
    assert WindowViews.resume_path(win2, "ws-a") == "/win2-view-of-a"
  end

  test "latest touch wins within a window" do
    WindowViews.touch(self(), "ws-a", "/first")
    WindowViews.touch(self(), "ws-a", "/second")
    assert WindowViews.resume_path(self(), "ws-a") == "/second"
  end

  test "nil connection / non-binary path are tolerated" do
    assert WindowViews.touch(nil, "ws-a", "/x") == :ok
    assert WindowViews.touch(self(), "ws-a", nil) == :ok
    assert WindowViews.resume_path(nil, "ws-a") == nil
  end

  test "a stale row past the TTL is expired and deleted on read" do
    :ets.insert(:window_views, {{self(), "ws-a"}, "/old", 0})
    assert WindowViews.resume_path(self(), "ws-a") == nil
    assert :ets.lookup(:window_views, {self(), "ws-a"}) == []
  end
end
