defmodule LoopyardWeb.Live.WorkspaceLive.Components.FormattersTest do
  use ExUnit.Case, async: true

  alias LoopyardWeb.Live.WorkspaceLive.Components.Formatters

  describe "service_status_text/1" do
    test "running returns nil" do
      assert Formatters.service_status_text(%{status: :running}) == nil
    end

    test "starting returns string" do
      assert Formatters.service_status_text(%{status: :starting}) == "starting"
    end

    test "crashed returns nil" do
      assert Formatters.service_status_text(%{status: :crashed}) == nil
    end

    test "stopped returns nil" do
      assert Formatters.service_status_text(%{status: :stopped}) == nil
    end

    test "unknown returns nil" do
      assert Formatters.service_status_text(%{status: :wat}) == nil
    end
  end

  describe "exit_reason/1" do
    test "OOM killed" do
      assert Formatters.exit_reason(%{oom_killed: true, exit_code: 137}) == "OOM killed"
    end

    test "custom error string" do
      assert Formatters.exit_reason(%{error: "segfault", exit_code: 1}) == "segfault"
    end

    test "clean exit" do
      assert Formatters.exit_reason(%{exit_code: 0}) == "exited cleanly"
    end

    test "SIGKILL" do
      assert Formatters.exit_reason(%{exit_code: 137}) == "killed (SIGKILL)"
    end

    test "SIGTERM" do
      assert Formatters.exit_reason(%{exit_code: 143}) == "stopped (SIGTERM)"
    end

    test "other exit code" do
      assert Formatters.exit_reason(%{exit_code: 2}) == "exit code 2"
    end

    test "fallback" do
      assert Formatters.exit_reason(%{}) == "stopped"
    end
  end

  describe "time_ago/1" do
    test "nil returns empty string" do
      assert Formatters.time_ago(nil) == ""
    end

    test "just now" do
      assert Formatters.time_ago(DateTime.utc_now()) == "just now"
    end

    test "seconds ago" do
      dt = DateTime.add(DateTime.utc_now(), -30, :second)
      assert Formatters.time_ago(dt) == "30s ago"
    end

    test "minutes ago" do
      dt = DateTime.add(DateTime.utc_now(), -300, :second)
      assert Formatters.time_ago(dt) == "5m ago"
    end

    test "hours ago" do
      dt = DateTime.add(DateTime.utc_now(), -7200, :second)
      assert Formatters.time_ago(dt) == "2h ago"
    end
  end

  describe "derive_volume_description/1" do
    test "code volume" do
      assert Formatters.derive_volume_description("loopyard-abc-code") == "Source code"
    end

    test "cache volume" do
      assert Formatters.derive_volume_description("loopyard-abc_cache-npm") == "Build cache"
    end

    test "postgres volume" do
      assert Formatters.derive_volume_description("loopyard-abc_postgres-data") ==
               "PostgreSQL data"
    end

    test "redis volume" do
      assert Formatters.derive_volume_description("loopyard-abc_redis-data") == "Redis data"
    end

    test "unknown returns name" do
      assert Formatters.derive_volume_description("loopyard-abc_mystery") ==
               "loopyard-abc_mystery"
    end
  end
end
