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
end
