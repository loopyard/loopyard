defmodule Loopyard.Docker.ObserverReliabilityTest do
  use ExUnit.Case, async: true

  alias Loopyard.Docker.Observer

  describe "backoff_delay/1" do
    # The schedule is 1s → 2s → 4s → 8s → 16s → 30s → 60s, then caps.
    # Any change to this shape should be conscious — assert the
    # invariants explicitly so a surprise reorder shows up as a test
    # failure, not a user-visible "reconnects take 3 hours now."

    test "first attempt is short so transient daemon blips recover fast" do
      assert Observer.backoff_delay(0) <= 1_000
    end

    test "caps on the largest defined interval, not unbounded" do
      # Simulate many attempts; delay must saturate, never grow past
      # ~60s (or whatever the final entry is).
      last = Observer.backoff_delay(100)
      assert last == Observer.backoff_delay(50)
      assert last <= 60_000
    end

    test "delays are monotonic non-decreasing" do
      delays = for attempt <- 0..10, do: Observer.backoff_delay(attempt)
      assert delays == Enum.sort(delays)
    end
  end

  describe "stale_cache_threshold/0" do
    test "is conservative enough to survive a Colima pause" do
      # 30s reconcile + debounced event-driven snapshots. Threshold
      # should cover at least ~30s of consecutive failures so a normal
      # daemon hiccup doesn't wipe the sidebar.
      assert Observer.stale_cache_threshold() >= 3
    end
  end

  describe "health/0" do
    @tag :docker
    test "returns a map with :connected, :last_snapshot_at, :snapshot_failures, :reconciles" do
      health = Observer.health()
      assert is_map(health)
      assert Map.has_key?(health, :connected)
      assert Map.has_key?(health, :last_snapshot_at)
      assert Map.has_key?(health, :snapshot_failures)
      assert Map.has_key?(health, :reconciles)
    end
  end
end
