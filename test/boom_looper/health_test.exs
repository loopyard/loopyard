defmodule BoomLooper.HealthTest do
  use ExUnit.Case, async: false

  alias BoomLooper.Health

  describe "components/0" do
    test "returns the set of tracked components" do
      assert :docker in Health.components()
      assert :pubsub in Health.components()
      assert :agent_reconciler in Health.components()
    end
  end

  describe "overall/0" do
    test "returns a status for every component" do
      map = Health.overall()
      assert Map.keys(map) |> Enum.sort() == Enum.sort(Health.components())
    end

    test "every status is a valid shape (:healthy | {:degraded, _} | {:down, _})" do
      for {_component, status} <- Health.overall() do
        assert status == :healthy or
                 match?({:degraded, reason} when is_binary(reason), status) or
                 match?({:down, reason} when is_binary(reason), status),
               "unexpected status shape: #{inspect(status)}"
      end
    end
  end

  describe "severity/0" do
    test "returns :healthy, :degraded, or :down" do
      assert Health.severity() in [:healthy, :degraded, :down]
    end

    test "severity follows component status aggregation" do
      # We can't force-flip real components, but we CAN assert the
      # aggregation logic directly by constructing an expected
      # severity from the current overall/0 output.
      statuses = Health.overall() |> Map.values()

      expected =
        cond do
          Enum.any?(statuses, &match?({:down, _}, &1)) -> :down
          Enum.any?(statuses, &match?({:degraded, _}, &1)) -> :degraded
          true -> :healthy
        end

      assert Health.severity() == expected
    end
  end

  describe "format/1" do
    test ":healthy formats to a simple word" do
      assert Health.format(:healthy) == "healthy"
    end

    test "degraded tuple formats with the reason" do
      assert Health.format({:degraded, "stream stalled"}) == "degraded — stream stalled"
    end

    test "down tuple formats with the reason" do
      assert Health.format({:down, "daemon unreachable"}) == "down — daemon unreachable"
    end
  end

  describe "component/1 — pubsub" do
    test "returns :healthy when Phoenix.PubSub is running" do
      # PubSub is started by the application supervision tree in tests.
      assert Health.component(:pubsub) == :healthy
    end
  end

  describe "component/1 — agent_reconciler" do
    test "returns a valid status even when no scan has run" do
      # The reconciler is in the application supervision tree; it
      # may or may not have had time to scan. Either way, the
      # status should be a valid shape.
      status = Health.component(:agent_reconciler)

      assert status == :healthy or
               match?({:degraded, _}, status) or
               match?({:down, _}, status)
    end
  end

  describe "component/1 — docker" do
    test "returns a valid status (does not raise even if Observer is unreachable)" do
      status = Health.component(:docker)

      assert status == :healthy or
               match?({:degraded, _}, status) or
               match?({:down, _}, status)
    end
  end
end
