defmodule BoomLooper.Tools.Container.TruncationTest do
  use ExUnit.Case, async: true

  alias BoomLooper.Tools.Container.Helpers

  describe "truncate_for_agent/2" do
    test "passes small output through unchanged" do
      output = "line 1\nline 2\nline 3"
      assert Helpers.truncate_for_agent(output) == output
    end

    test "truncates large output to tail lines" do
      lines = for i <- 1..500, do: "line #{i} #{String.duplicate("x", 50)}"
      output = Enum.join(lines, "\n")

      result = Helpers.truncate_for_agent(output)

      # Should be much smaller than original
      assert byte_size(result) < byte_size(output)

      # Should contain the last lines
      assert result =~ "line 500"
      assert result =~ "line 499"

      # Should contain truncation notice
      assert result =~ "bytes total"
      assert result =~ "showing last 80 lines"

      # Should NOT contain early lines
      refute result =~ "line 1\n"
    end

    test "respects custom max" do
      output = String.duplicate("x", 100)

      # With high max, no truncation
      assert Helpers.truncate_for_agent(output, max: 200) == output

      # With low max, truncated
      result = Helpers.truncate_for_agent(output, max: 50)
      assert result =~ "bytes total"
    end

    test "respects custom tail lines" do
      lines = for i <- 1..100, do: "line #{i}"
      output = Enum.join(lines, "\n")

      result = Helpers.truncate_for_agent(output, max: 100, tail: 5)
      assert result =~ "showing last 5 lines"
      assert result =~ "line 100"
      assert result =~ "line 96"
    end

    test "handles empty string" do
      assert Helpers.truncate_for_agent("") == ""
    end

    test "handles single line" do
      assert Helpers.truncate_for_agent("hello") == "hello"
    end

    test "handles output exactly at max" do
      output = String.duplicate("a", 8_000)
      assert Helpers.truncate_for_agent(output) == output
    end

    test "handles output 1 byte over max" do
      output = String.duplicate("a", 8_001)
      result = Helpers.truncate_for_agent(output)
      assert result =~ "bytes total"
    end
  end

  describe "truncation in tool results" do
    test "docker compose build output is truncated for agent" do
      # Simulate what happens with a large compose build
      build_output = for i <- 1..1000, do: "Step #{i}/1000: installing package-#{i}"
      large = Enum.join(build_output, "\n")

      # The agent should get a summary, not the full output
      result = Helpers.truncate_for_agent(large, max: 4_000, tail: 50)

      # summary + 50 lines
      assert byte_size(result) < 6_000
      # has the end
      assert result =~ "Step 1000/1000"
      # doesn't start with the beginning
      refute String.starts_with?(result, "Step 1/")
    end

    test "exec output from large file listing is truncated" do
      # Simulate `find / -type f`
      files = for i <- 1..5000, do: "/usr/share/doc/package-#{i}/README"
      large = Enum.join(files, "\n")

      result = Helpers.truncate_for_agent(large)
      assert byte_size(result) < 10_000
      assert result =~ "package-5000"
    end

    test "short exec output passes through unchanged" do
      output = "total 42\ndrwxr-xr-x 5 root root 4096 Jan 1 00:00 .\n"
      assert Helpers.truncate_for_agent(output) == output
    end
  end

  describe "UI vs agent output separation" do
    test "full output available for UI, truncated for agent" do
      build_log = for i <- 1..500, do: "Building layer #{i}..."
      full_output = Enum.join(build_log, "\n")

      # UI gets the full thing (this is what goes to PubSub/ETS)
      assert byte_size(full_output) > 10_000

      # Agent gets truncated version (this is the tool return value)
      agent_result = Helpers.truncate_for_agent(full_output)
      assert byte_size(agent_result) < byte_size(full_output)

      # Both contain the final line
      assert full_output =~ "Building layer 500"
      assert agent_result =~ "Building layer 500"

      # Only full output has early lines
      assert full_output =~ "Building layer 1..."
      refute agent_result =~ "Building layer 1..."
    end
  end
end
