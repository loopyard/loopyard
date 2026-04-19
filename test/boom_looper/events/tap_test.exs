defmodule BoomLooper.Events.TapTest do
  use ExUnit.Case, async: false

  alias BoomLooper.Events.Tap

  setup do
    # Tap is part of the application supervision tree and is already
    # running in the test env. Clear the ETS table between tests so
    # assertions aren't tripped by leftover records from other tests.
    :ets.delete_all_objects(:events_tap)
    :ok
  end

  describe "topic classification" do
    test "chat_agents events are bucketed correctly" do
      Phoenix.PubSub.broadcast(BoomLooper.PubSub, "chat_agents", {:chat_agent_started, %{id: "a"}})
      Process.sleep(50)

      events = Tap.recent()
      assert [%{topic: "chat_agents", tag: :chat_agent_started}] = events
    end

    test "chat_agent_status_changed is classified as chat_agents" do
      Phoenix.PubSub.broadcast(BoomLooper.PubSub, "chat_agents", {:chat_agent_status_changed, "id", :idle})
      Process.sleep(50)

      events = Tap.recent()
      assert Enum.any?(events, &(&1.topic == "chat_agents" and &1.tag == :chat_agent_status_changed))
    end

    test "docker_observer events are bucketed correctly" do
      Phoenix.PubSub.broadcast(BoomLooper.PubSub, "docker_observer", {:docker_state_changed})
      Phoenix.PubSub.broadcast(BoomLooper.PubSub, "docker_observer", {:docker_state_disconnected})
      Process.sleep(50)

      events = Tap.recent()
      assert Enum.any?(events, &(&1.topic == "docker_observer" and &1.tag == :docker_state_changed))
      assert Enum.any?(events, &(&1.topic == "docker_observer" and &1.tag == :docker_state_disconnected))
    end

    test "workspace_services events are bucketed correctly" do
      Phoenix.PubSub.broadcast(BoomLooper.PubSub, "workspace_services", {:services_updated, "/tmp/ws"})
      Phoenix.PubSub.broadcast(BoomLooper.PubSub, "workspace_services", {:compose_result, "ws-1", :ok})
      Process.sleep(50)

      events = Tap.recent()
      assert Enum.any?(events, &(&1.topic == "workspace_services" and &1.tag == :services_updated))
      assert Enum.any?(events, &(&1.topic == "workspace_services" and &1.tag == :compose_result))
    end
  end

  describe "recent/1 filters" do
    setup do
      Phoenix.PubSub.broadcast(BoomLooper.PubSub, "chat_agents", {:chat_agent_started, %{id: "1"}})
      Phoenix.PubSub.broadcast(BoomLooper.PubSub, "docker_observer", {:docker_state_changed})
      Phoenix.PubSub.broadcast(BoomLooper.PubSub, "chat_agents", {:chat_agent_stopped, %{id: "2"}})
      Process.sleep(50)
      :ok
    end

    test "topic filter returns only events on that topic" do
      events = Tap.recent(topic: "chat_agents")
      assert length(events) == 2
      assert Enum.all?(events, &(&1.topic == "chat_agents"))
    end

    test "limit caps the number of returned events" do
      events = Tap.recent(limit: 1)
      assert length(events) == 1
    end

    test "since_ms filter returns only events newer than the given monotonic time" do
      # Capture 'now' after the setup broadcasts landed
      cutoff = System.monotonic_time(:millisecond)
      Process.sleep(10)

      Phoenix.PubSub.broadcast(BoomLooper.PubSub, "chat_agents", {:chat_agent_booting, %{id: "new"}})
      Process.sleep(50)

      events = Tap.recent(since_ms: cutoff)
      assert length(events) == 1
      assert hd(events).tag == :chat_agent_booting
    end

    test "newest events come first" do
      events = Tap.recent()
      # Two of these are from setup; the newest is :chat_agent_stopped
      [newest | _] = events
      assert newest.tag == :chat_agent_stopped
    end
  end

  describe "topic_counts/0" do
    test "returns per-topic count of captured events" do
      Phoenix.PubSub.broadcast(BoomLooper.PubSub, "chat_agents", {:chat_agent_started, %{}})
      Phoenix.PubSub.broadcast(BoomLooper.PubSub, "chat_agents", {:chat_agent_stopped, %{}})
      Phoenix.PubSub.broadcast(BoomLooper.PubSub, "docker_observer", {:docker_state_changed})
      Process.sleep(50)

      counts = Tap.topic_counts()
      assert counts["chat_agents"] == 2
      assert counts["docker_observer"] == 1
    end
  end

  describe "payload truncation" do
    test "oversized payloads are truncated with a marker" do
      big = String.duplicate("x", 5_000)
      Phoenix.PubSub.broadcast(BoomLooper.PubSub, "chat_agents", {:chat_agent_started, %{blob: big}})
      Process.sleep(50)

      [event] = Tap.recent()
      assert String.ends_with?(event.payload, "…(truncated)")
      assert byte_size(event.payload) < 5_000
    end

    test "small payloads are NOT truncated" do
      Phoenix.PubSub.broadcast(BoomLooper.PubSub, "chat_agents", {:chat_agent_started, %{id: "small"}})
      Process.sleep(50)

      [event] = Tap.recent()
      refute String.ends_with?(event.payload, "…(truncated)")
    end
  end
end
