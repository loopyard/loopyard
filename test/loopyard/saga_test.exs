defmodule Loopyard.SagaTest do
  use ExUnit.Case, async: true

  alias Loopyard.Saga

  # Helper: collect telemetry events emitted during a block.
  defp collect_telemetry(event_names, fun) do
    parent = self()
    ref = make_ref()

    handler_id = {__MODULE__, ref}

    :telemetry.attach_many(
      handler_id,
      event_names,
      fn event, measurements, meta, _ ->
        send(parent, {ref, event, measurements, meta})
      end,
      nil
    )

    result =
      try do
        fun.()
      after
        :telemetry.detach(handler_id)
      end

    events = drain_events(ref, [])

    {result, events}
  end

  defp drain_events(ref, acc) do
    receive do
      {^ref, event, measurements, meta} ->
        drain_events(ref, [{event, measurements, meta} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "run/2 — happy path" do
    test "runs every step in order and returns the merged context" do
      steps = [
        %{
          name: :step_one,
          run: fn ctx ->
            assert ctx == %{seed: 1}
            {:ok, %{one: "done"}}
          end
        },
        %{
          name: :step_two,
          run: fn ctx ->
            assert ctx == %{seed: 1, one: "done"}
            {:ok, %{two: "also done"}}
          end
        },
        %{
          name: :step_three,
          run: fn ctx ->
            assert ctx.one == "done"
            assert ctx.two == "also done"
            {:ok, %{three: "finito"}}
          end
        }
      ]

      assert {:ok, ctx} = Saga.run(steps, name: :unit_test, context: %{seed: 1})
      assert ctx == %{seed: 1, one: "done", two: "also done", three: "finito"}
    end

    test "steps with no rollback are fine on the happy path" do
      steps = [
        %{name: :read, run: fn _ -> {:ok, %{v: 1}} end}
      ]

      assert {:ok, %{v: 1}} = Saga.run(steps, name: :unit_test)
    end

    test "empty step list returns the initial context" do
      assert {:ok, %{x: 1}} = Saga.run([], name: :unit_test, context: %{x: 1})
    end
  end

  describe "run/2 — failure triggers rollback in reverse order" do
    test "runs rollbacks LIFO for completed steps" do
      parent = self()

      steps = [
        %{
          name: :a,
          run: fn _ ->
            send(parent, {:ran, :a})
            {:ok, %{a: :ok}}
          end,
          rollback: fn _ ->
            send(parent, {:rolled_back, :a})
            :ok
          end
        },
        %{
          name: :b,
          run: fn _ ->
            send(parent, {:ran, :b})
            {:ok, %{b: :ok}}
          end,
          rollback: fn _ ->
            send(parent, {:rolled_back, :b})
            :ok
          end
        },
        %{
          name: :c,
          run: fn _ ->
            send(parent, {:ran, :c})
            {:error, :blew_up}
          end,
          rollback: fn _ ->
            send(parent, {:rolled_back, :c})
            :ok
          end
        },
        %{
          name: :d,
          run: fn _ ->
            send(parent, {:ran, :d})
            {:ok, %{d: :ok}}
          end
        }
      ]

      assert {:error, {:step_failed, :c, :blew_up}, :rolled_back} =
               Saga.run(steps, name: :unit_test)

      assert_received {:ran, :a}
      assert_received {:ran, :b}
      assert_received {:ran, :c}
      # d never ran — c failed
      refute_received {:ran, :d}

      # Rollbacks fire LIFO for COMPLETED steps. c never succeeded, so
      # its rollback doesn't run.
      assert_received {:rolled_back, :b}
      assert_received {:rolled_back, :a}
      refute_received {:rolled_back, :c}
    end

    test "failure in the first step triggers no rollbacks" do
      parent = self()

      steps = [
        %{
          name: :a,
          run: fn _ -> {:error, :boom} end,
          rollback: fn _ ->
            send(parent, :should_not_fire)
            :ok
          end
        }
      ]

      assert {:error, {:step_failed, :a, :boom}, :rolled_back} =
               Saga.run(steps, name: :unit_test)

      refute_received :should_not_fire
    end

    test "rollback sees the context from completed steps" do
      parent = self()

      steps = [
        %{
          name: :a,
          run: fn _ -> {:ok, %{a: :created, resource: :abc123}} end,
          rollback: fn ctx ->
            send(parent, {:rollback_saw, ctx.a, ctx.resource})
            :ok
          end
        },
        %{
          name: :b,
          run: fn _ -> {:error, :nope} end
        }
      ]

      assert {:error, {:step_failed, :b, :nope}, :rolled_back} =
               Saga.run(steps, name: :unit_test)

      assert_received {:rollback_saw, :created, :abc123}
    end
  end

  describe "run/2 — rollback failures" do
    test "failed rollback is collected and surfaced" do
      steps = [
        %{
          name: :a,
          run: fn _ -> {:ok, %{}} end,
          rollback: fn _ -> {:error, :rollback_broke} end
        },
        %{
          name: :b,
          run: fn _ -> {:error, :forward_broke} end
        }
      ]

      assert {:error, {:step_failed, :b, :forward_broke},
              {:rollback_failed, [{:a, :rollback_broke}]}} =
               Saga.run(steps, name: :unit_test)
    end

    test "subsequent rollbacks still run after one fails" do
      parent = self()

      steps = [
        %{
          name: :a,
          run: fn _ -> {:ok, %{}} end,
          rollback: fn _ ->
            send(parent, {:rolled_back, :a})
            :ok
          end
        },
        %{
          name: :b,
          run: fn _ -> {:ok, %{}} end,
          rollback: fn _ -> {:error, :b_failed} end
        },
        %{
          name: :c,
          run: fn _ -> {:error, :triggered} end
        }
      ]

      assert {:error, {:step_failed, :c, :triggered}, {:rollback_failed, [{:b, :b_failed}]}} =
               Saga.run(steps, name: :unit_test)

      # a's rollback still ran even though b's failed
      assert_received {:rolled_back, :a}
    end

    test "crashing rollback is caught and recorded" do
      steps = [
        %{
          name: :a,
          run: fn _ -> {:ok, %{}} end,
          rollback: fn _ -> raise "boom in rollback" end
        },
        %{
          name: :b,
          run: fn _ -> {:error, :nope} end
        }
      ]

      assert {:error, {:step_failed, :b, :nope},
              {:rollback_failed, [{:a, {:exception, "boom in rollback"}}]}} =
               Saga.run(steps, name: :unit_test)
    end
  end

  describe "run/2 — exceptions in forward fn" do
    test "raise is caught and treated as an error" do
      steps = [
        %{
          name: :a,
          run: fn _ -> raise "kaboom" end
        }
      ]

      assert {:error, {:step_failed, :a, {:exception, "kaboom"}}, :rolled_back} =
               Saga.run(steps, name: :unit_test)
    end

    test "exit is caught and treated as an error" do
      steps = [
        %{
          name: :a,
          run: fn _ -> exit(:normal) end
        }
      ]

      assert {:error, {:step_failed, :a, {:exit, :normal}}, :rolled_back} =
               Saga.run(steps, name: :unit_test)
    end
  end

  describe "run/2 — bad returns" do
    test "step returning something that isn't ok/error is classified as a bad_return failure" do
      steps = [
        %{
          name: :a,
          run: fn _ -> :nope end
        }
      ]

      assert {:error, {:step_failed, :a, {:bad_return, :nope}}, :rolled_back} =
               Saga.run(steps, name: :unit_test)
    end
  end

  describe "telemetry" do
    test "fires started + step_succeeded + completed for the happy path" do
      steps = [
        %{name: :one, run: fn _ -> {:ok, %{}} end},
        %{name: :two, run: fn _ -> {:ok, %{}} end}
      ]

      {_result, events} =
        collect_telemetry(
          [
            [:loopyard, :saga, :started],
            [:loopyard, :saga, :step_succeeded],
            [:loopyard, :saga, :step_failed],
            [:loopyard, :saga, :completed]
          ],
          fn -> Saga.run(steps, name: :tel_test) end
        )

      names = Enum.map(events, fn {e, _, _} -> e end)

      assert [:loopyard, :saga, :started] in names
      assert [:loopyard, :saga, :completed] in names

      step_succeeded_events =
        Enum.filter(events, fn {e, _, _} -> e == [:loopyard, :saga, :step_succeeded] end)

      assert length(step_succeeded_events) == 2
    end

    test "fires step_failed + rolled_back + step_rolled_back on failure" do
      steps = [
        %{
          name: :one,
          run: fn _ -> {:ok, %{}} end,
          rollback: fn _ -> :ok end
        },
        %{
          name: :two,
          run: fn _ -> {:error, :nope} end
        }
      ]

      {_result, events} =
        collect_telemetry(
          [
            [:loopyard, :saga, :started],
            [:loopyard, :saga, :step_failed],
            [:loopyard, :saga, :step_rolled_back],
            [:loopyard, :saga, :rolled_back]
          ],
          fn -> Saga.run(steps, name: :tel_test) end
        )

      names = Enum.map(events, fn {e, _, _} -> e end)

      assert [:loopyard, :saga, :step_failed] in names
      assert [:loopyard, :saga, :step_rolled_back] in names
      assert [:loopyard, :saga, :rolled_back] in names
    end

    test "fires rollback_failed when a rollback fn errors" do
      steps = [
        %{
          name: :one,
          run: fn _ -> {:ok, %{}} end,
          rollback: fn _ -> {:error, :cant_undo} end
        },
        %{
          name: :two,
          run: fn _ -> {:error, :nope} end
        }
      ]

      {_result, events} =
        collect_telemetry(
          [[:loopyard, :saga, :rollback_failed]],
          fn -> Saga.run(steps, name: :tel_test) end
        )

      assert [{[:loopyard, :saga, :rollback_failed], _, meta}] = events
      assert meta.saga == :tel_test
      assert meta.step == :one
    end

    test "metadata is threaded through every event" do
      steps = [%{name: :one, run: fn _ -> {:ok, %{}} end}]

      {_result, events} =
        collect_telemetry(
          [
            [:loopyard, :saga, :started],
            [:loopyard, :saga, :completed]
          ],
          fn ->
            Saga.run(steps, name: :tel_test, metadata: %{workspace_id: "abc"})
          end
        )

      for {_event, _measurements, meta} <- events do
        assert meta.workspace_id == "abc"
        assert meta.saga == :tel_test
      end
    end
  end

  describe "maybe_log_rollback_failed/3 — call-site surfacing (audit LOW #16)" do
    test ":rolled_back is a no-op — emits no telemetry" do
      {_result, events} =
        collect_telemetry(
          [[:loopyard, :saga, :call_site_rollback_failed]],
          fn ->
            Saga.maybe_log_rollback_failed(:rolled_back, :unit_test, %{foo: 1})
          end
        )

      assert events == []
    end

    test "{:rollback_failed, list} logs error + emits telemetry with saga_name + metadata" do
      failed = [{:step_a, :boom}, {:step_b, {:exception, "nope"}}]

      logs =
        ExUnit.CaptureLog.capture_log(fn ->
          {_result, events} =
            collect_telemetry(
              [[:loopyard, :saga, :call_site_rollback_failed]],
              fn ->
                Saga.maybe_log_rollback_failed(
                  {:rollback_failed, failed},
                  :my_saga,
                  %{workspace_id: "ws-1"}
                )
              end
            )

          assert [{[:loopyard, :saga, :call_site_rollback_failed], measurements, meta}] =
                   events

          assert measurements.count == 2
          assert meta.saga_name == :my_saga
          assert meta.workspace_id == "ws-1"
          assert meta.failed_rollbacks == failed
        end)

      assert logs =~ "rollback FAILED"
      assert logs =~ "my_saga"
      assert logs =~ ":step_a"
      assert logs =~ ":step_b"
    end

    test "call-site path fires when Saga.run/2 returns {:rollback_failed, _}" do
      # End-to-end: exercise via Saga.run itself with a step that has
      # a broken rollback + a later step that fails forward. Confirms
      # the shape of the third tuple element is compatible with the
      # helper and the helper fires call_site_rollback_failed telemetry.
      steps = [
        %{
          name: :write,
          run: fn _ -> {:ok, %{}} end,
          rollback: fn _ -> {:error, :disk_full} end
        },
        %{name: :finalize, run: fn _ -> {:error, :boom} end}
      ]

      {:error, {:step_failed, :finalize, :boom}, rollback_outcome} =
        Saga.run(steps, name: :integration_test, journal?: false)

      assert {:rollback_failed, [{:write, :disk_full}]} = rollback_outcome

      {_result, events} =
        collect_telemetry(
          [[:loopyard, :saga, :call_site_rollback_failed]],
          fn ->
            Saga.maybe_log_rollback_failed(
              rollback_outcome,
              :integration_test,
              %{caller: :unit}
            )
          end
        )

      assert [{[:loopyard, :saga, :call_site_rollback_failed], %{count: 1}, meta}] = events
      assert meta.saga_name == :integration_test
      assert meta.caller == :unit
      assert meta.failed_rollbacks == [{:write, :disk_full}]
    end
  end

  describe "validation" do
    test "step missing :name raises" do
      assert_raise ArgumentError, fn ->
        Saga.run([%{run: fn _ -> {:ok, %{}} end}], name: :t)
      end
    end

    test "step missing :run raises" do
      assert_raise ArgumentError, fn ->
        Saga.run([%{name: :x}], name: :t)
      end
    end

    test "run not a 1-arity fn raises" do
      assert_raise ArgumentError, fn ->
        Saga.run([%{name: :x, run: fn -> {:ok, %{}} end}], name: :t)
      end
    end

    test "run without name option raises" do
      assert_raise KeyError, fn ->
        Saga.run([], [])
      end
    end
  end
end
