defmodule BoomLooper.EventLogTest do
  use ExUnit.Case, async: false

  alias BoomLooper.EventLog

  setup do
    # Clear events between tests. Tables are pre-created by StateKeeper
    # when the application starts.
    :ets.delete_all_objects(:event_log)
    :ok
  end

  describe "log/3" do
    test "stores events that can be retrieved" do
      EventLog.info("system", "test message")
      events = EventLog.recent()
      assert length(events) == 1
      assert hd(events).source == "system"
      assert hd(events).message == "test message"
      assert hd(events).level == :info
    end

    test "stores multiple events in order" do
      EventLog.info("a", "first")
      EventLog.warning("b", "second")
      EventLog.error("c", "third")

      events = EventLog.recent()
      assert length(events) == 3
      # recent/1 returns newest first
      assert Enum.map(events, & &1.message) == ["third", "second", "first"]
    end

    test "each event has a timestamp" do
      EventLog.info("test", "with timestamp")
      [event] = EventLog.recent()
      assert %DateTime{} = event.timestamp
    end
  end

  describe "recent/1" do
    test "limits to N events" do
      for i <- 1..10, do: EventLog.info("test", "msg #{i}")
      assert length(EventLog.recent(3)) == 3
    end

    test "returns empty list when no events" do
      assert EventLog.recent() == []
    end
  end

  describe "trim" do
    test "trims oldest events when exceeding max_events (200)" do
      for i <- 1..210 do
        EventLog.info("test", "msg #{i}")
      end

      events = EventLog.recent(300)
      assert length(events) == 200

      # Oldest events should be trimmed — newest should remain
      messages = Enum.map(events, & &1.message)
      assert "msg 210" in messages
      refute "msg 1" in messages
    end
  end

  describe "dump/1" do
    test "formats events as plain text" do
      EventLog.error("agent:Setup", "crash happened")
      text = EventLog.dump()
      assert text =~ "ERROR"
      assert text =~ "[agent:Setup]"
      assert text =~ "crash happened"
    end
  end

end
