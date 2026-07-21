defmodule Loopyard.Harness.ConformanceTest do
  @moduledoc """
  Behaviour conformance: every concrete `Loopyard.Harness` implementation
  must export every callback of the behaviour at the right arity.

  This is the cheap guard that catches a backend drifting out of shape — e.g.
  adding a callback to the behaviour but forgetting to implement it in one of
  the backends, or a backend renaming/dropping a function the ChatAgent calls.
  """
  use ExUnit.Case, async: true

  @behaviour_mod Loopyard.Harness

  # ACP is the only production backend (harnesses run in-container); Fake is the
  # test double. There is no host-execution backend — Harness.Claude was deleted.
  @backends [
    Loopyard.Harness.ACP,
    Loopyard.Harness.Fake
  ]

  test "the behaviour declares the callbacks we expect" do
    callbacks = MapSet.new(@behaviour_mod.behaviour_info(:callbacks))

    expected =
      MapSet.new([
        {:start_session, 1},
        {:stream, 2},
        {:stop, 1},
        {:cancel_turn, 1},
        {:session_alive?, 1},
        {:session_id, 1}
      ])

    assert MapSet.equal?(callbacks, expected),
           "Backend behaviour callbacks drifted: #{inspect(MapSet.to_list(callbacks))}"
  end

  for backend <- @backends do
    test "#{inspect(backend)} exports every behaviour callback" do
      backend = unquote(backend)
      Code.ensure_loaded!(backend)

      for {fun, arity} <- @behaviour_mod.behaviour_info(:callbacks) do
        assert function_exported?(backend, fun, arity),
               "#{inspect(backend)} is missing #{fun}/#{arity}"
      end
    end

    test "#{inspect(backend)} declares @behaviour Loopyard.Harness" do
      backend = unquote(backend)
      Code.ensure_loaded!(backend)

      behaviours =
        backend.module_info(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert @behaviour_mod in behaviours,
             "#{inspect(backend)} does not declare @behaviour #{inspect(@behaviour_mod)}"
    end
  end
end
