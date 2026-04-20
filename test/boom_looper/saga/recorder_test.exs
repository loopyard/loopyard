defmodule BoomLooper.Saga.RecorderTest do
  @moduledoc """
  Tests the Recorder against real Saga runs. The Recorder attaches
  to telemetry at init/1 time and is already running under the test
  app (started in `BoomLooper.Application`), so each test just needs
  to run a saga and assert the resulting record.

  Not `async: true` because Recorder shares ETS state across tests.
  """
  use ExUnit.Case, async: false

  alias BoomLooper.{Saga, Saga.Recorder}

  setup do
    # Clear any prior records so each test sees a clean slate.
    :ets.delete_all_objects(Recorder.table())
    :ok
  end

  describe "happy-path recording" do
    test "records a successful saga with every step marked succeeded" do
      steps = [
        %{name: :a, run: fn _ -> {:ok, %{}} end},
        %{name: :b, run: fn _ -> {:ok, %{}} end}
      ]

      assert {:ok, _} = Saga.run(steps, name: :recorder_success_test)

      # Telemetry fires synchronously, so the record is populated by
      # the time Saga.run/2 returns.
      [record] = Recorder.recent(saga: :recorder_success_test)
      assert record.status == :succeeded
      assert record.saga == :recorder_success_test
      assert length(record.completed_steps) == 2
      assert Enum.all?(record.completed_steps, &(&1.status == :succeeded))
      assert record.failed_step == nil
      assert record.finished_at != nil
    end
  end

  describe "failure recording" do
    test "records which step failed + which rolled back" do
      steps = [
        %{name: :first, run: fn _ -> {:ok, %{}} end, rollback: fn _ -> :ok end},
        %{name: :second, run: fn _ -> {:ok, %{}} end, rollback: fn _ -> :ok end},
        %{name: :third, run: fn _ -> {:error, :boom} end}
      ]

      assert {:error, {:step_failed, :third, :boom}, :rolled_back} =
               Saga.run(steps, name: :recorder_failure_test)

      [record] = Recorder.recent(saga: :recorder_failure_test)
      assert record.status == :rolled_back
      assert record.failed_step == :third
      assert :first in record.rolled_back_steps
      assert :second in record.rolled_back_steps
      # The failing step itself is recorded but not rolled back (it
      # never succeeded, so there's nothing to undo).
      refute :third in record.rolled_back_steps
    end

    test "records rollback_failed status when any rollback errors" do
      steps = [
        %{
          name: :first,
          run: fn _ -> {:ok, %{}} end,
          rollback: fn _ -> {:error, :rollback_broke} end
        },
        %{name: :second, run: fn _ -> {:error, :triggered} end}
      ]

      assert {:error, _, {:rollback_failed, _}} =
               Saga.run(steps, name: :recorder_rollback_failed_test)

      [record] = Recorder.recent(saga: :recorder_rollback_failed_test)
      assert record.status == :rollback_failed
      assert record.failed_rollbacks != []
      assert Enum.any?(record.failed_rollbacks, fn {step, _} -> step == :first end)
    end
  end

  describe "summary/0" do
    test "aggregates counts across all recorded sagas" do
      # succeed
      Saga.run([%{name: :a, run: fn _ -> {:ok, %{}} end}],
        name: :summary_test_a
      )

      # rolled back
      Saga.run(
        [
          %{name: :a, run: fn _ -> {:ok, %{}} end, rollback: fn _ -> :ok end},
          %{name: :b, run: fn _ -> {:error, :nope} end}
        ],
        name: :summary_test_b
      )

      # rollback failed
      Saga.run(
        [
          %{
            name: :a,
            run: fn _ -> {:ok, %{}} end,
            rollback: fn _ -> {:error, :undo_busted} end
          },
          %{name: :b, run: fn _ -> {:error, :trigger} end}
        ],
        name: :summary_test_c
      )

      summary = Recorder.summary()
      assert summary.total >= 3
      assert summary.succeeded >= 1
      assert summary.rolled_back >= 1
      assert summary.rollback_failed >= 1
    end
  end

  describe "missing saga_id metadata (defense-in-depth)" do
    # A producer emitting a saga event without :saga_id is a bug
    # anywhere in the chain. Previously the recorder silently dropped
    # these — no log, no telemetry, no breadcrumbs. Now it warns +
    # emits :actor.unknown_message, matching the handle_info pattern.

    test "logs a warning when a saga event is missing :saga_id" do
      import ExUnit.CaptureLog

      log =
        capture_log(fn ->
          # Fire any non-:started saga event with no :saga_id. The
          # recorder's handler routes into update/2, which now warns
          # + emits telemetry instead of silently returning :ok.
          :telemetry.execute([:boom_looper, :saga, :completed], %{}, %{saga: :bogus})
          # Telemetry handlers run synchronously in the publishing
          # process, so no sleep needed.
        end)

      assert log =~ "Saga.Recorder"
      assert log =~ "missing :saga_id"
    end

    test "emits [:boom_looper, :actor, :unknown_message] telemetry" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:boom_looper, :actor, :unknown_message]
        ])

      :telemetry.execute([:boom_looper, :saga, :rolled_back], %{}, %{saga: :bogus})

      assert_receive {[:boom_looper, :actor, :unknown_message], ^ref, %{count: 1},
                      %{actor: BoomLooper.Saga.Recorder, reason: :missing_saga_id}},
                     500

      :telemetry.detach(ref)
    end
  end

  describe "recent/1 filtering" do
    test "filters to a single saga name" do
      Saga.run([%{name: :a, run: fn _ -> {:ok, %{}} end}], name: :filter_test_one)
      Saga.run([%{name: :a, run: fn _ -> {:ok, %{}} end}], name: :filter_test_two)

      ones = Recorder.recent(saga: :filter_test_one)
      twos = Recorder.recent(saga: :filter_test_two)

      assert length(ones) >= 1
      assert length(twos) >= 1
      assert Enum.all?(ones, &(&1.saga == :filter_test_one))
      assert Enum.all?(twos, &(&1.saga == :filter_test_two))
    end

    test "limit caps the result size" do
      for _ <- 1..5 do
        Saga.run([%{name: :a, run: fn _ -> {:ok, %{}} end}], name: :limit_test)
      end

      assert Recorder.recent(saga: :limit_test, limit: 2) |> length() == 2
    end
  end
end
