defmodule Loopyard.Saga.RecorderTest do
  @moduledoc """
  Tests the Recorder against real Saga runs. The Recorder attaches
  to telemetry at init/1 time and is already running under the test
  app (started in `Loopyard.Application`), so each test just needs
  to run a saga and assert the resulting record.

  Not `async: true` because Recorder shares ETS state across tests.
  """
  use ExUnit.Case, async: false

  alias Loopyard.{Saga, Saga.Recorder}

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
          :telemetry.execute([:loopyard, :saga, :completed], %{}, %{saga: :bogus})
          # Telemetry handlers run synchronously in the publishing
          # process, so no sleep needed.
        end)

      assert log =~ "Saga.Recorder"
      assert log =~ "missing :saga_id"
    end

    test "emits [:loopyard, :actor, :unknown_message] telemetry" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:loopyard, :actor, :unknown_message]
        ])

      :telemetry.execute([:loopyard, :saga, :rolled_back], %{}, %{saga: :bogus})

      assert_receive {[:loopyard, :actor, :unknown_message], ^ref, %{count: 1},
                      %{actor: Loopyard.Saga.Recorder, reason: :missing_saga_id}},
                     500

      :telemetry.detach(ref)
    end
  end

  describe "sort-by-started_at robustness (audit-2 LOW #11)" do
    # Pre-fix: `recent/0` sorted on the string saga_id and
    # `maybe_trim/0` did the same in ascending order. Lex sort happens
    # to be chronological with today's "#{ts}-#{seq}" format, but
    # that's a property of the current format — not a contract. The
    # fix routes both through `started_at` on the record so ordering
    # survives a future id-format change.

    test "recent/0 returns newest-first by started_at even when saga_ids sort the other way" do
      # Inject records directly into the ETS table in order to control
      # saga_id + started_at independently. The string ids here would
      # sort the reverse of what chronological sort produces.
      now = DateTime.utc_now()
      older = DateTime.add(now, -10, :second)
      oldest = DateTime.add(now, -30, :second)

      # id "a" newest (should come first), id "z" oldest (should come last)
      :ets.insert(
        Recorder.table(),
        {"a",
         %{
           saga_id: "a",
           saga: :s,
           status: :succeeded,
           started_at: now,
           finished_at: now,
           step_count: 0,
           completed_steps: [],
           failed_step: nil,
           failure_reason: nil,
           rolled_back_steps: [],
           failed_rollbacks: [],
           metadata: %{}
         }}
      )

      :ets.insert(
        Recorder.table(),
        {"m",
         %{
           saga_id: "m",
           saga: :s,
           status: :succeeded,
           started_at: older,
           finished_at: older,
           step_count: 0,
           completed_steps: [],
           failed_step: nil,
           failure_reason: nil,
           rolled_back_steps: [],
           failed_rollbacks: [],
           metadata: %{}
         }}
      )

      :ets.insert(
        Recorder.table(),
        {"z",
         %{
           saga_id: "z",
           saga: :s,
           status: :succeeded,
           started_at: oldest,
           finished_at: oldest,
           step_count: 0,
           completed_steps: [],
           failed_step: nil,
           failure_reason: nil,
           rolled_back_steps: [],
           failed_rollbacks: [],
           metadata: %{}
         }}
      )

      ids = Recorder.recent(saga: :s) |> Enum.map(& &1.saga_id)
      assert ids == ["a", "m", "z"]
    end

    test "recent/0 tolerates records with nil started_at" do
      # If someone ever injects a malformed record the sort must not
      # blow up. Nil started_at sorts oldest.
      now = DateTime.utc_now()

      :ets.insert(
        Recorder.table(),
        {"A",
         %{
           saga_id: "A",
           saga: :nil_test,
           status: :succeeded,
           started_at: now,
           finished_at: now,
           step_count: 0,
           completed_steps: [],
           failed_step: nil,
           failure_reason: nil,
           rolled_back_steps: [],
           failed_rollbacks: [],
           metadata: %{}
         }}
      )

      :ets.insert(
        Recorder.table(),
        {"B",
         %{
           saga_id: "B",
           saga: :nil_test,
           status: :succeeded,
           started_at: nil,
           finished_at: nil,
           step_count: 0,
           completed_steps: [],
           failed_step: nil,
           failure_reason: nil,
           rolled_back_steps: [],
           failed_rollbacks: [],
           metadata: %{}
         }}
      )

      ids = Recorder.recent(saga: :nil_test) |> Enum.map(& &1.saga_id)
      # newest (A with a DateTime) before the nil-started_at entry.
      assert ids == ["A", "B"]
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
