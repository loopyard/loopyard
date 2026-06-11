defmodule Loopyard.Session.ViewTrackerTest do
  use ExUnit.Case, async: false

  alias Loopyard.Session.ViewTracker

  setup do
    # StateKeeper owns :session_views; ensure it exists for the test run.
    Loopyard.StateKeeper.ensure_tables!()
    :ets.delete_all_objects(:session_views)
    :ok
  end

  test "resume_path returns nil until a view is touched" do
    assert ViewTracker.resume_path("sess-1", "ws-a") == nil
  end

  test "touch records the last view per (session, workspace)" do
    :ok = ViewTracker.touch("sess-1", "ws-a", "/projects/p/workspaces/ws-a/services/dev")
    assert ViewTracker.resume_path("sess-1", "ws-a") == "/projects/p/workspaces/ws-a/services/dev"
  end

  test "the latest touch wins" do
    ViewTracker.touch("sess-1", "ws-a", "/first")
    ViewTracker.touch("sess-1", "ws-a", "/second")
    assert ViewTracker.resume_path("sess-1", "ws-a") == "/second"
  end

  test "views are isolated per session and per workspace" do
    ViewTracker.touch("sess-1", "ws-a", "/a")
    ViewTracker.touch("sess-1", "ws-b", "/b")
    ViewTracker.touch("sess-2", "ws-a", "/other")

    assert ViewTracker.resume_path("sess-1", "ws-a") == "/a"
    assert ViewTracker.resume_path("sess-1", "ws-b") == "/b"
    assert ViewTracker.resume_path("sess-2", "ws-a") == "/other"
    assert ViewTracker.resume_path("sess-2", "ws-b") == nil
  end

  test "nil/non-binary session ids are tolerated (no crash)" do
    assert ViewTracker.touch(nil, "ws-a", "/x") == :ok
    assert ViewTracker.resume_path(nil, "ws-a") == nil
  end

  test "a stale row past the TTL is expired and deleted on read" do
    # Write a row with an ancient timestamp directly, then read it.
    :ets.insert(:session_views, {{"sess-1", "ws-a"}, "/old", 0})
    assert ViewTracker.resume_path("sess-1", "ws-a") == nil
    assert :ets.lookup(:session_views, {"sess-1", "ws-a"}) == []
  end
end
