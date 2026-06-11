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

  test "3 windows in the same browser each keep an independent switcher" do
    # Each browser window/tab is its own LiveView connection (transport_pid).
    [w1, w2, w3] = for _ <- 1..3, do: spawn(fn -> :ok end)

    # Each window wanders to a different place across the SAME two workspaces.
    WindowViews.touch(w1, "main", "/main/services/dev")
    WindowViews.touch(w1, "feature", "/feature/agents/a1")

    WindowViews.touch(w2, "main", "/main/agents/a2")
    WindowViews.touch(w2, "feature", "/feature/volumes/code/files/lib")

    WindowViews.touch(w3, "main", "/main/git")
    # w3 never visited feature → no resume there.

    # Every window resumes ONLY its own trail. No bleed between the three.
    assert WindowViews.resume_path(w1, "main") == "/main/services/dev"
    assert WindowViews.resume_path(w1, "feature") == "/feature/agents/a1"

    assert WindowViews.resume_path(w2, "main") == "/main/agents/a2"
    assert WindowViews.resume_path(w2, "feature") == "/feature/volumes/code/files/lib"

    assert WindowViews.resume_path(w3, "main") == "/main/git"
    assert WindowViews.resume_path(w3, "feature") == nil
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

  test "clear removes all of a connection's rows, leaving other windows intact" do
    other = spawn(fn -> :ok end)
    WindowViews.touch(self(), "ws-a", "/a")
    WindowViews.touch(self(), "ws-b", "/b")
    WindowViews.touch(other, "ws-a", "/other-a")

    :ok = WindowViews.clear(self())

    # This connection's rows are gone…
    assert WindowViews.resume_path(self(), "ws-a") == nil
    assert WindowViews.resume_path(self(), "ws-b") == nil
    # …but another window's are untouched.
    assert WindowViews.resume_path(other, "ws-a") == "/other-a"
  end
end
