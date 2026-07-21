defmodule Loopyard.Harness.MemoryMonitorTest do
  @moduledoc """
  Unit tests for the proactive harness memory monitor's parsing + thresholds.
  The fiddly part is turning `docker stats`' "used / limit" MemUsage strings
  into bytes across unit suffixes; a wrong multiplier silently disables the
  whole safety valve.
  """
  use ExUnit.Case, async: true

  alias Loopyard.Harness.MemoryMonitor

  describe "parse_used_bytes/1 (via the module's private fn)" do
    # Exercise the parser through a tiny reflection helper so the unit math is
    # pinned without needing Docker.
    defp used(mem), do: apply(MemoryMonitor, :parse_used_bytes, [mem])

    test "parses the USED side across binary units" do
      assert used("512MiB / 8GiB") == 512 * 1024 * 1024
      assert used("1.5GiB / 8GiB") == round(1.5 * 1024 * 1024 * 1024)
      assert used("66.32MiB / 8GiB") == round(66.32 * 1024 * 1024)
      assert used("900B / 8GiB") == 900
    end

    test "handles SI units Docker sometimes prints" do
      assert used("2GB / 8GB") == 2 * 1000 * 1000 * 1000
      assert used("500kB / 8GB") == 500 * 1000
    end

    test "returns nil on garbage rather than crashing the sweep" do
      assert used("n/a / n/a") == nil
      assert used("") == nil
    end
  end

  describe "unit_multiplier/1" do
    defp mult(u), do: apply(MemoryMonitor, :unit_multiplier, [u])

    test "GiB is the binary gigabyte, GB the decimal one" do
      assert mult("GiB") == 1024 * 1024 * 1024
      assert mult("GB") == 1_000_000_000
      assert mult("gib") == 1024 * 1024 * 1024
    end

    test "unknown units multiply to zero (parsed value collapses, never over-counts)" do
      assert mult("wat") == 0
    end
  end
end
