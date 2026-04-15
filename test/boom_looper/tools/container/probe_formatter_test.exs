defmodule BoomLooper.Tools.Container.ProbeFormatterTest do
  use ExUnit.Case, async: true

  alias BoomLooper.Tools.Container.ProbeFormatter

  describe "format_probe_no_response/3 — headline classification" do
    # The headline tells the agent at a glance WHY every probe failed.
    # This matters because "refused on every port" → chase bind config;
    # "timed out on every port" → app is starting, wait. The old
    # formatter said "connection refused" for both cases, which
    # misdiagnosed cold-start app latency as a 127.0.0.1 binding bug
    # (exactly what happened to bookstack evals — php-fpm was slow,
    # agent chased nginx config for several nudges).

    test "all-refused headline points at bind config" do
      attempted = [
        {"bl-abc-dev-1", 80, "32894", :refused,
         "port not accepting TCP — unbound, wrong address, or 127.0.0.1"},
        {"bl-abc-dev-1", 3000, "32895", :refused, "same"}
      ]

      output =
        ProbeFormatter.format_probe_no_response(
          attempted,
          "/",
          %{"bl-abc-dev-1" => true}
        )

      assert output =~ "REFUSED"
      assert output =~ "not bound"
      refute output =~ "slow to respond"
    end

    test "all-timeout headline points at cold start" do
      attempted = [
        {"bl-abc-dev-1", 80, "32894", :timeout, "connected but no response in 30s"}
      ]

      output =
        ProbeFormatter.format_probe_no_response(
          attempted,
          "/",
          %{"bl-abc-dev-1" => true}
        )

      assert output =~ "TIMED OUT"
      assert output =~ "slow to respond"
      refute output =~ "not bound"
    end

    test "mixed reasons show per-URL detail without a wrong verdict" do
      attempted = [
        {"bl-abc-dev-1", 80, "32894", :refused, "nothing listening"},
        {"bl-abc-dev-1", 3000, "32895", :timeout, "cold start"}
      ]

      output =
        ProbeFormatter.format_probe_no_response(
          attempted,
          "/",
          %{"bl-abc-dev-1" => true}
        )

      assert output =~ "mixed reasons"
      assert output =~ "refused"
      assert output =~ "timeout"
    end

    test "includes every attempted URL with its failure kind" do
      attempted = [
        {"bl-abc-workspace-1", 3000, "32001", :refused, "no listener"},
        {"bl-abc-dev-1", 80, "32002", :timeout, "slow boot"}
      ]

      output =
        ProbeFormatter.format_probe_no_response(
          attempted,
          "/login",
          %{"bl-abc-workspace-1" => true, "bl-abc-dev-1" => true}
        )

      assert output =~ "http://localhost:32001/login"
      assert output =~ "http://localhost:32002/login"
      assert output =~ "bl-abc-workspace-1:3000"
      assert output =~ "bl-abc-dev-1:80"
    end
  end
end
