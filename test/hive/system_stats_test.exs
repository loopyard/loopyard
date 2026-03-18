defmodule Hive.SystemStatsTest do
  use ExUnit.Case, async: true

  alias Hive.SystemStats

  describe "host_stats" do
    test "returns CPU, memory, disk, and uptime" do
      stats = SystemStats.host_stats()
      assert is_map(stats.cpu)
      assert stats.cpu.cores > 0
      assert is_list(stats.cpu.load_avg)
      assert length(stats.cpu.load_avg) == 3

      assert is_map(stats.memory)
      assert stats.memory.total > 0

      assert is_map(stats.disk)
      assert is_binary(stats.disk.total)

      assert is_binary(stats.uptime)
    end
  end

  describe "beam_stats" do
    test "returns BEAM VM stats" do
      stats = SystemStats.beam_stats()
      assert stats.total > 0
      assert stats.processes > 0
      assert stats.ets > 0
      assert stats.process_count > 0
      assert stats.schedulers > 0
    end
  end

  describe "agent_stats" do
    # agent_stats calls docker stats, which is slow/can hang
    @describetag :docker

    test "returns list (possibly empty)" do
      stats = SystemStats.agent_stats()
      assert is_list(stats)
    end
  end
end
