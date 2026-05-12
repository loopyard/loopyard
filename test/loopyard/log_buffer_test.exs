defmodule Loopyard.LogBufferTest do
  use ExUnit.Case

  alias Loopyard.LogBuffer

  test "captures log messages" do
    require Logger
    marker = "log_buffer_test_#{:rand.uniform(999_999)}"
    Logger.warning(marker)
    Logger.flush()
    Process.sleep(100)

    entries = LogBuffer.recent(50)

    assert Enum.any?(entries, fn e -> String.contains?(e.message, marker) end),
           "Expected to find '#{marker}' in #{length(entries)} log entries"
  end

  test "grep filters by pattern" do
    require Logger
    marker = "grep_marker_#{:rand.uniform(999_999)}"
    Logger.warning(marker)
    Logger.flush()
    Process.sleep(100)

    results = LogBuffer.grep(marker)
    assert length(results) >= 1
    assert hd(results).level == :warning
  end

  test "recent returns newest first" do
    require Logger
    m1 = "order_first_#{:rand.uniform(999_999)}"
    m2 = "order_second_#{:rand.uniform(999_999)}"
    Logger.warning(m1)
    Logger.warning(m2)
    Logger.flush()
    Process.sleep(100)

    entries = LogBuffer.recent(20)
    messages = Enum.map(entries, & &1.message)
    first_idx = Enum.find_index(messages, &String.contains?(&1, m1))
    second_idx = Enum.find_index(messages, &String.contains?(&1, m2))

    if first_idx && second_idx do
      assert second_idx < first_idx, "Newest should be first"
    end
  end
end
