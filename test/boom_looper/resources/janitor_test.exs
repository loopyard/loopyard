defmodule BoomLooper.Resources.JanitorTest do
  @moduledoc """
  Janitor-level tests. `BoomLooper.ResourcesTest` covers the public
  API end-to-end; this module exercises the janitor internals:
  telemetry, force_release_for_owner, DOWN-handler robustness, and
  the shape of release_fns it accepts.
  """
  use ExUnit.Case, async: false

  alias BoomLooper.Resources
  alias BoomLooper.Resources.Janitor

  setup do
    :ets.delete_all_objects(Janitor.table())
    :ok
  end

  describe "telemetry" do
    test "fires :tracked on first track and :released on owner DOWN" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:boom_looper, :resources, :tracked],
          [:boom_looper, :resources, :released]
        ])

      {owner, monitor_ref} = spawn_owner()
      Resources.track(owner, :tel_kind, 1, fn -> :ok end)

      assert_receive {[:boom_looper, :resources, :tracked], ^ref, _, %{kind: :tel_kind}},
                     500

      send(owner, :stop)
      assert_receive {:DOWN, ^monitor_ref, :process, ^owner, _}, 500

      assert_receive {[:boom_looper, :resources, :released], ^ref, _,
                      %{kind: :tel_kind, reason: :owner_down}},
                     500

      :telemetry.detach(ref)
    end

    test "idempotent re-track does NOT re-fire :tracked telemetry" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:boom_looper, :resources, :tracked]])

      {owner, _} = spawn_owner()
      Resources.track(owner, :tel_idem, 1, nil)
      assert_receive {[:boom_looper, :resources, :tracked], ^ref, _, _}, 500

      # Second call — same owner, same kind/id. Should not emit.
      Resources.track(owner, :tel_idem, 1, nil)
      refute_receive {[:boom_looper, :resources, :tracked], ^ref, _, _}, 100

      send(owner, :stop)
      :telemetry.detach(ref)
    end

    test "explicit release fires :released with reason :explicit" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:boom_looper, :resources, :released]])

      {owner, _} = spawn_owner()
      Resources.track(owner, :tel_expl, 7, nil)
      :ok = Resources.release(:tel_expl, 7)

      assert_receive {[:boom_looper, :resources, :released], ^ref, _,
                      %{kind: :tel_expl, reason: :explicit}},
                     500

      send(owner, :stop)
      :telemetry.detach(ref)
    end

    test "release_fn that crashes fires :released with reason :release_fn_error" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:boom_looper, :resources, :released]])

      {owner, _} = spawn_owner()

      Resources.track(owner, :tel_err, 1, fn -> raise "nope" end)
      :ok = Resources.release(:tel_err, 1)

      assert_receive {[:boom_looper, :resources, :released], ^ref, _,
                      %{kind: :tel_err, reason: :release_fn_error}},
                     500

      send(owner, :stop)
      :telemetry.detach(ref)
    end
  end

  describe "force_release_for_owner/1" do
    test "runs release_fns and returns the list of released resources" do
      test_pid = self()
      {owner, _} = spawn_owner()

      Resources.track(owner, :force_kind, :a, fn -> send(test_pid, :a_released) end)
      Resources.track(owner, :force_kind, :b, fn -> send(test_pid, :b_released) end)

      assert {:ok, released} = Janitor.force_release_for_owner(owner)
      assert length(released) == 2

      assert_receive :a_released, 500
      assert_receive :b_released, 500

      assert Resources.list_for_owner(owner) == []

      send(owner, :stop)
    end

    test "no-op for an owner with no tracked resources" do
      {owner, _} = spawn_owner()
      assert {:ok, []} = Janitor.force_release_for_owner(owner)
      send(owner, :stop)
    end
  end

  describe "release_fn shape validation" do
    test "non-zero-arity function is treated as an error without crashing the janitor" do
      {owner, _} = spawn_owner()

      # Intentionally malformed: single-arg fn. Janitor logs + marks
      # as release_fn_error but does NOT crash.
      Resources.track(owner, :bad_arity, :x, fn _ -> :ok end)

      assert :ok = Resources.release(:bad_arity, :x)
      # Janitor is still alive + responsive.
      assert is_list(Resources.all())

      send(owner, :stop)
    end
  end

  describe "monitor lifecycle" do
    test "demonitors an owner after its last resource is released" do
      {owner, _} = spawn_owner()

      Resources.track(owner, :mon_kind, 1, nil)
      Resources.track(owner, :mon_kind, 2, nil)

      :ok = Resources.release(:mon_kind, 1)
      :ok = Resources.release(:mon_kind, 2)

      # No rows — force_release_for_owner is a cheap roundtrip that
      # also asserts the janitor's state is consistent. If the owner
      # were still monitored, by_owner would still contain it.
      assert {:ok, []} = Janitor.force_release_for_owner(owner)

      send(owner, :stop)
    end

    test "stale DOWN (already demonitored) is ignored cleanly" do
      # Track + release, which demonitors. Then kill the owner
      # anyway — the delayed DOWN message, if any, must not crash
      # the janitor or attempt to re-release.
      {owner, ref} = spawn_owner()
      Resources.track(owner, :stale_down, 1, nil)
      :ok = Resources.release(:stale_down, 1)

      send(owner, :stop)
      assert_receive {:DOWN, ^ref, :process, ^owner, _}, 500

      # Janitor remains alive + responsive.
      assert is_list(Resources.all())
    end
  end

  describe "rehydrate from ETS on janitor restart" do
    # Audit HIGH #4 + audit-2 MEDIUM #3 (commits 02d42f6 + 35f07cc).
    # The janitor used to call `:ets.delete_all_objects(@table)` on
    # init, leaking every tracked resource whose owner survived the
    # restart. Post-fix: it re-monitors surviving owners and drops
    # only dead-owner rows. Audit-2 MEDIUM #3: dead-owner rows must
    # ALSO run their release_fn before deletion, otherwise OS-level
    # resources (e.g. port bindings) orphan.

    test "surviving owner still has active tracking after janitor crash" do
      test_pid = self()
      {owner, _} = spawn_owner()

      Resources.track(owner, :rehydrate_survivor, :r1, fn ->
        send(test_pid, :released_after_rehydrate)
      end)

      assert [_] = :ets.lookup(Janitor.table(), {:rehydrate_survivor, :r1})

      # Crash the janitor. The named supervisor will bring it back;
      # on init it must re-monitor the still-alive owner so the
      # release_fn fires when the owner eventually dies.
      janitor_pid = Process.whereis(Janitor)
      assert is_pid(janitor_pid)
      ref = Process.monitor(janitor_pid)
      Process.exit(janitor_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^janitor_pid, _}, 1_000

      new_pid = wait_for_janitor_restart(janitor_pid)
      assert new_pid != janitor_pid

      # Row for the live owner stayed in ETS.
      assert [{_, ^owner, _fn, _ts}] =
               :ets.lookup(Janitor.table(), {:rehydrate_survivor, :r1})

      # Now kill the owner — the new janitor must still fire the
      # release_fn, proving it re-monitored the pid on rehydrate.
      send(owner, :stop)
      assert_receive :released_after_rehydrate, 1_000

      # ETS row is cleaned up by the new janitor's DOWN handler.
      # The release_fn's `send` runs just before `:ets.delete`, so
      # receiving the message doesn't guarantee the row is gone yet
      # — poll briefly.
      wait_until(fn ->
        :ets.lookup(Janitor.table(), {:rehydrate_survivor, :r1}) == []
      end)
    end

    test "dead-owner release_fn runs during rehydrate, ETS row deleted" do
      test_pid = self()

      # Spawn an owner, track under it, then kill the owner BEFORE
      # the janitor dies — simulating "owner already gone when the
      # janitor restarts" (happens in practice when an owner's crash
      # and a sibling crash are coincident).
      owner = spawn(fn -> :ok end)
      # Wait for owner to actually exit.
      ref_owner = Process.monitor(owner)
      assert_receive {:DOWN, ^ref_owner, :process, ^owner, _}, 500
      refute Process.alive?(owner)

      # Insert directly into ETS with the dead owner. Going through
      # Resources.track/4 would monitor the pid and, since
      # Process.monitor on a dead pid fires DOWN immediately, the
      # live janitor would release the row BEFORE we get a chance to
      # crash the janitor. Direct insert skips that path and sets up
      # the "janitor was dead while owner died" race we want to test.
      ts = System.monotonic_time(:microsecond)

      :ets.insert(
        Janitor.table(),
        {{:rehydrate_dead, :r1}, owner, fn -> send(test_pid, :released_on_rehydrate) end, ts}
      )

      orphan_ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:boom_looper, :resources, :orphan]
        ])

      # Crash the janitor; the rehydrate path must fire the release_fn
      # and delete the row (audit-2 MEDIUM #3).
      janitor_pid = Process.whereis(Janitor)
      assert is_pid(janitor_pid)
      mref = Process.monitor(janitor_pid)
      Process.exit(janitor_pid, :kill)
      assert_receive {:DOWN, ^mref, :process, ^janitor_pid, _}, 1_000

      _new_pid = wait_for_janitor_restart(janitor_pid)

      # Release_fn fired during rehydrate (not just when the next
      # DOWN arrives — there's no pid left to send DOWN).
      assert_receive :released_on_rehydrate, 1_500

      # Orphan telemetry fired with the rehydrate-specific reason.
      assert_receive {[:boom_looper, :resources, :orphan], ^orphan_ref, _,
                      %{kind: :rehydrate_dead, id: :r1, reason: :owner_dead_on_janitor_restart}},
                     1_500

      # ETS row gone. run_release fires telemetry/sends before the
      # :ets.delete call inside rehydrate_from_ets, so the lookup
      # can race the delete — poll briefly.
      wait_until(fn ->
        :ets.lookup(Janitor.table(), {:rehydrate_dead, :r1}) == []
      end)

      :telemetry.detach(orphan_ref)
    end
  end

  # ── Helpers ──

  defp spawn_owner do
    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    ref = Process.monitor(pid)
    {pid, ref}
  end

  defp wait_until(fun, deadline_ms \\ 1_000) do
    started = System.monotonic_time(:millisecond)

    loop = fn loop ->
      cond do
        fun.() ->
          :ok

        System.monotonic_time(:millisecond) - started > deadline_ms ->
          flunk("wait_until: condition not met within #{deadline_ms}ms")

        true ->
          Process.sleep(10)
          loop.(loop)
      end
    end

    loop.(loop)
  end

  defp wait_for_janitor_restart(old_pid, deadline_ms \\ 2_000) do
    started = System.monotonic_time(:millisecond)

    loop = fn loop ->
      case Process.whereis(Janitor) do
        nil ->
          if System.monotonic_time(:millisecond) - started > deadline_ms do
            flunk("janitor did not restart")
          end

          Process.sleep(20)
          loop.(loop)

        ^old_pid ->
          if System.monotonic_time(:millisecond) - started > deadline_ms do
            flunk("janitor pid unchanged after kill")
          end

          Process.sleep(20)
          loop.(loop)

        new_pid ->
          new_pid
      end
    end

    loop.(loop)
  end
end
