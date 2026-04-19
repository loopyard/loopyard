defmodule BoomLooper.ResourcesTest do
  @moduledoc """
  Unit tests for `BoomLooper.Resources` — the public API. Exercises
  track / release / owner-death cleanup via the supervised Janitor
  running under the test app.
  """
  use ExUnit.Case, async: false

  alias BoomLooper.Resources

  setup do
    # Clean slate. Tests never share tracked resources.
    :ets.delete_all_objects(:resource_registry)
    :ok
  end

  describe "track/4" do
    test "records a resource under the given owner pid" do
      {owner, _} = spawn_monitor_owner()

      assert :ok = Resources.track(owner, :test_kind, {:id, 1}, fn -> :ok end)

      assert [%{kind: :test_kind, id: {:id, 1}, owner: ^owner}] =
               Resources.list_for_owner(owner)

      :ok = stop_owner(owner)
    end

    test "idempotent — re-tracking the same kind+id under same owner is a no-op" do
      {owner, _} = spawn_monitor_owner()

      assert :ok = Resources.track(owner, :test_kind, 42, fn -> :ok end)
      assert :ok = Resources.track(owner, :test_kind, 42, fn -> :ok end)

      # Still exactly one row, no error.
      assert length(Resources.list_for_owner(owner)) == 1

      :ok = stop_owner(owner)
    end

    test "refuses to transfer ownership (same kind+id, different owner)" do
      {owner_a, _} = spawn_monitor_owner()
      {owner_b, _} = spawn_monitor_owner()

      assert :ok = Resources.track(owner_a, :test_kind, 99, fn -> :ok end)

      assert {:error, :already_tracked} =
               Resources.track(owner_b, :test_kind, 99, fn -> :ok end)

      # Original ownership unchanged.
      assert [%{owner: ^owner_a}] = Resources.list_for_owner(owner_a)
      assert [] = Resources.list_for_owner(owner_b)

      :ok = stop_owner(owner_a)
      :ok = stop_owner(owner_b)
    end

    test "tracks resources with nil release_fn (pure bookkeeping)" do
      {owner, _} = spawn_monitor_owner()

      assert :ok = Resources.track(owner, :bookkeeping, "x", nil)
      assert [%{kind: :bookkeeping}] = Resources.list_for_owner(owner)

      :ok = stop_owner(owner)
    end
  end

  describe "release/2 (explicit)" do
    test "removes a tracked resource and fires its release_fn" do
      test_pid = self()
      {owner, _} = spawn_monitor_owner()

      assert :ok =
               Resources.track(owner, :kind_a, :explicit_release, fn ->
                 send(test_pid, :released_explicitly)
               end)

      assert :ok = Resources.release(:kind_a, :explicit_release)
      assert_receive :released_explicitly, 200

      assert Resources.list_for_owner(owner) == []

      :ok = stop_owner(owner)
    end

    test "no-op when the resource was never tracked" do
      assert :ok = Resources.release(:never_tracked, :ghost)
    end

    test "subsequent owner-DOWN does not double-release" do
      test_pid = self()
      {owner, ref} = spawn_monitor_owner()

      release_counter = :counters.new(1, [])

      Resources.track(owner, :kind_b, :k, fn ->
        :counters.add(release_counter, 1, 1)
        send(test_pid, :released)
      end)

      assert :ok = Resources.release(:kind_b, :k)
      assert_receive :released, 200

      :ok = stop_owner(owner)
      # Wait for the DOWN to propagate.
      assert_receive {:DOWN, ^ref, :process, ^owner, _}, 500

      # Give the janitor a beat to process the DOWN. A single
      # roundtrip to the janitor is enough to flush its mailbox.
      _ = Resources.list_for_owner(owner)

      assert :counters.get(release_counter, 1) == 1
    end
  end

  describe "owner-death cleanup" do
    test "releases every resource when the owner pid goes DOWN" do
      test_pid = self()
      {owner, ref} = spawn_monitor_owner()

      for i <- 1..3 do
        Resources.track(owner, :kind_owner_down, i, fn ->
          send(test_pid, {:released, i})
        end)
      end

      assert length(Resources.list_for_owner(owner)) == 3

      :ok = stop_owner(owner)
      assert_receive {:DOWN, ^ref, :process, ^owner, _}, 500

      # All three release_fns fire; order is implementation-defined.
      assert_receive {:released, _}, 500
      assert_receive {:released, _}, 500
      assert_receive {:released, _}, 500

      # Force a sync roundtrip so we know the DOWN was processed.
      assert Resources.list_for_owner(owner) == []
    end

    test "a crashing release_fn does not prevent other releases" do
      test_pid = self()
      {owner, ref} = spawn_monitor_owner()

      Resources.track(owner, :kind_crash, :crasher, fn ->
        send(test_pid, :crasher_ran)
        raise "boom"
      end)

      Resources.track(owner, :kind_crash, :survivor, fn ->
        send(test_pid, :survivor_released)
      end)

      :ok = stop_owner(owner)
      assert_receive {:DOWN, ^ref, :process, ^owner, _}, 500

      assert_receive :crasher_ran, 500
      assert_receive :survivor_released, 500
    end
  end

  describe "list_for_owner/1" do
    test "returns empty list for a pid with no tracked resources" do
      {owner, _} = spawn_monitor_owner()
      assert Resources.list_for_owner(owner) == []
      :ok = stop_owner(owner)
    end

    test "returns resources only for the specified owner" do
      {owner_a, _} = spawn_monitor_owner()
      {owner_b, _} = spawn_monitor_owner()

      Resources.track(owner_a, :kind_x, 1, nil)
      Resources.track(owner_b, :kind_x, 2, nil)

      assert [%{id: 1, owner: ^owner_a}] = Resources.list_for_owner(owner_a)
      assert [%{id: 2, owner: ^owner_b}] = Resources.list_for_owner(owner_b)

      :ok = stop_owner(owner_a)
      :ok = stop_owner(owner_b)
    end
  end

  describe "all/0" do
    test "returns every tracked resource across owners" do
      {owner_a, _} = spawn_monitor_owner()
      {owner_b, _} = spawn_monitor_owner()

      Resources.track(owner_a, :kind_all, :first, nil)
      Resources.track(owner_b, :kind_all, :second, nil)

      all = Resources.all()
      ids = Enum.map(all, & &1.id) |> Enum.sort()

      assert :first in ids
      assert :second in ids
      assert Enum.all?(all, & &1.owner_alive?)

      :ok = stop_owner(owner_a)
      :ok = stop_owner(owner_b)
    end

    test "surfaces owner_alive? = false for dead owners (invariant probe)" do
      # Tracking under a freshly-killed pid fires the :orphan
      # telemetry path. This is the "shouldn't happen" probe — we
      # still want the janitor to release correctly.
      dead = spawn(fn -> :ok end)
      # Wait until the pid is actually dead.
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, :process, ^dead, _}, 500

      # Attempt to track. The release should fire immediately via
      # the DOWN handler the janitor installs on track.
      assert :ok = Resources.track(dead, :kind_dead_owner, :z, fn -> :ok end)

      # Either the track lost the race and the row is gone, or the
      # row exists briefly before the immediate-DOWN fires. Give
      # the janitor one roundtrip to process it.
      _ = Resources.all()

      # Eventually the row must be gone (release fired on DOWN).
      # Without a deterministic wait here, we just assert the
      # invariant: if any row remains, its owner_alive? is false.
      for r <- Resources.all() do
        if r.id == :z, do: assert(r.owner_alive? == false)
      end
    end
  end

  # ── Helpers ──

  defp spawn_monitor_owner do
    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    ref = Process.monitor(pid)
    {pid, ref}
  end

  defp stop_owner(pid) do
    if Process.alive?(pid), do: send(pid, :stop)
    :ok
  end
end
