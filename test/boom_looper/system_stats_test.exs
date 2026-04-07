defmodule BoomLooper.SystemStatsTest do
  use ExUnit.Case, async: true

  alias BoomLooper.SystemStats

  # Each public function in SystemStats is one independently-loadable
  # slice. These tests pin that contract: every slice must be safe to
  # call on its own (no implicit "load everything" function), so a
  # LiveView can fetch them in parallel without one slow slice blocking
  # another.

  describe "host_cpu" do
    @tag :macos
    test "returns core count and 3 load averages" do
      cpu = SystemStats.host_cpu()
      assert cpu.cores > 0
      assert is_list(cpu.load_avg)
      assert length(cpu.load_avg) == 3
      assert Enum.all?(cpu.load_avg, &is_float/1)
    end
  end

  describe "host_memory" do
    @tag :macos
    test "returns total/used/free" do
      mem = SystemStats.host_memory()
      assert mem.total > 0
      assert mem.used >= 0
      assert mem.free >= 0
    end
  end

  describe "host_disk" do
    test "returns df shape with binary fields" do
      disk = SystemStats.host_disk()
      assert is_binary(disk.total)
      assert is_binary(disk.used)
      assert is_binary(disk.available)
      assert is_binary(disk.use_pct)
    end
  end

  describe "host_uptime" do
    test "returns a non-empty string" do
      uptime = SystemStats.host_uptime()
      assert is_binary(uptime)
      assert uptime != ""
    end
  end

  describe "beam_stats" do
    test "returns BEAM VM stats — no shell calls, must be instant" do
      {micros, stats} = :timer.tc(fn -> SystemStats.beam_stats() end)
      # BEAM-only call: should complete in microseconds, not milliseconds.
      # If this ever blows past 10ms it means someone added a shell-out.
      assert micros < 10_000, "beam_stats took #{micros}µs — did someone add a shell call?"
      assert stats.total > 0
      assert stats.processes > 0
      assert stats.ets > 0
      assert stats.process_count > 0
      assert stats.schedulers > 0
    end
  end

  describe "workspace_stats" do
    test "returns a list — no shell calls, must be instant" do
      {micros, result} = :timer.tc(fn -> SystemStats.workspace_stats() end)
      assert micros < 50_000, "workspace_stats took #{micros}µs — should be Registry-only"
      assert is_list(result)
    end
  end

  describe "agent_stats/2" do
    test "composes agent rows from pre-fetched docker stats and CLI list" do
      # Pure compose path — no shell calls when both slices are passed in.
      assert is_list(SystemStats.agent_stats(%{}, []))
    end
  end

  describe "service_stats/1" do
    @describetag :docker
    test "returns list (possibly empty)" do
      assert is_list(SystemStats.service_stats(%{}))
    end
  end

  describe "claude_cli_processes" do
    test "returns a list" do
      assert is_list(SystemStats.claude_cli_processes())
    end
  end
end
