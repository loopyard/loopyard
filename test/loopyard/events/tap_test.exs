defmodule Loopyard.Events.TapTest do
  use ExUnit.Case, async: false

  alias Loopyard.Events.Tap

  setup do
    # Tap is part of the application supervision tree and is already
    # running in the test env. Clear the ETS table between tests so
    # assertions aren't tripped by leftover records from other tests.
    :ets.delete_all_objects(:events_tap)
    :ok
  end

  describe "topic classification" do
    # All tap tests use unique ids — the tap is supervised and
    # captures broadcasts from any concurrent test. Find OUR event
    # in the buffer rather than asserting on buffer shape.

    test "chat_agents events (struct form via publisher) are bucketed correctly" do
      id = "cls-chat-struct-#{System.unique_integer([:positive])}"

      Loopyard.Events.ChatAgent.publish(%Loopyard.Events.ChatAgent.Started{
        summary: %{id: id}
      })

      Process.sleep(50)

      event = Enum.find(Tap.recent(), &String.contains?(&1.payload, id))
      assert event != nil
      assert event.topic == "chat_agents"
      assert event.tag == Loopyard.Events.ChatAgent.Started
    end

    test "chat_agents events (legacy tuple fallback) are still bucketed" do
      id = "cls-chat-tuple-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.broadcast(Loopyard.PubSub, "chat_agents", {:chat_agent_started, %{id: id}})
      Process.sleep(50)

      event = Enum.find(Tap.recent(), &String.contains?(&1.payload, id))
      assert event != nil
      assert event.topic == "chat_agents"
      assert event.tag == :chat_agent_started
    end

    test "chat_agent_status_changed is classified as chat_agents" do
      id = "cls-status-#{System.unique_integer([:positive])}"

      Phoenix.PubSub.broadcast(
        Loopyard.PubSub,
        "chat_agents",
        {:chat_agent_status_changed, id, :idle}
      )

      Process.sleep(50)

      event = Enum.find(Tap.recent(), &String.contains?(&1.payload, id))
      assert event != nil
      assert event.topic == "chat_agents"
      assert event.tag == :chat_agent_status_changed
    end

    test "docker_observer events are bucketed correctly" do
      # Observer broadcasts are tuple-only with no unique id in the
      # payload — capture their sequence numbers as the unique
      # discriminator.
      before_seqs = Tap.recent() |> Enum.map(& &1.seq) |> MapSet.new()
      Phoenix.PubSub.broadcast(Loopyard.PubSub, "docker_observer", {:docker_state_changed})
      Phoenix.PubSub.broadcast(Loopyard.PubSub, "docker_observer", {:docker_state_disconnected})
      Process.sleep(50)

      new_events =
        Tap.recent() |> Enum.reject(&MapSet.member?(before_seqs, &1.seq))

      assert Enum.any?(
               new_events,
               &(&1.topic == "docker_observer" and &1.tag == :docker_state_changed)
             )

      assert Enum.any?(
               new_events,
               &(&1.topic == "docker_observer" and &1.tag == :docker_state_disconnected)
             )
    end

    test "workspace_services events are bucketed correctly" do
      id = "cls-ws-#{System.unique_integer([:positive])}"

      Phoenix.PubSub.broadcast(
        Loopyard.PubSub,
        "workspace_services",
        {:services_updated, "/tmp/#{id}"}
      )

      Phoenix.PubSub.broadcast(
        Loopyard.PubSub,
        "workspace_services",
        {:compose_result, id, :ok}
      )

      Process.sleep(50)

      events = Enum.filter(Tap.recent(), &String.contains?(&1.payload, id))

      assert Enum.any?(
               events,
               &(&1.topic == "workspace_services" and &1.tag == :services_updated)
             )

      assert Enum.any?(events, &(&1.topic == "workspace_services" and &1.tag == :compose_result))
    end
  end

  describe "recent/1 filters" do
    setup do
      # Use unique markers so concurrent broadcasts from other tests
      # don't pollute our assertions. The exact `length == 2` check
      # broke under parallel load when sibling test broadcasts on
      # chat_agents landed in our window.
      m1 = "tap-test-started-#{System.unique_integer([:positive])}"
      m2 = "tap-test-stopped-#{System.unique_integer([:positive])}"

      Phoenix.PubSub.broadcast(Loopyard.PubSub, "chat_agents", {:chat_agent_started, %{id: m1}})
      Phoenix.PubSub.broadcast(Loopyard.PubSub, "docker_observer", {:docker_state_changed})
      Phoenix.PubSub.broadcast(Loopyard.PubSub, "chat_agents", {:chat_agent_stopped, %{id: m2}})
      Process.sleep(50)
      %{m1: m1, m2: m2}
    end

    test "topic filter returns only events on that topic", %{m1: m1, m2: m2} do
      events = Tap.recent(topic: "chat_agents")
      # Both our markers must be present; everything returned must be
      # on chat_agents topic. We don't assert the exact length because
      # other tests may emit chat_agents events concurrently.
      assert Enum.any?(events, &String.contains?(&1.payload, m1))
      assert Enum.any?(events, &String.contains?(&1.payload, m2))
      assert Enum.all?(events, &(&1.topic == "chat_agents"))
    end

    test "limit caps the number of returned events" do
      events = Tap.recent(limit: 1)
      assert length(events) == 1
    end

    test "since_ms filter returns only events newer than the given monotonic time" do
      cutoff = System.monotonic_time(:millisecond)
      Process.sleep(10)

      id = "since-test-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.broadcast(Loopyard.PubSub, "chat_agents", {:chat_agent_booting, %{id: id}})
      Process.sleep(50)

      events = Tap.recent(since_ms: cutoff)
      # There may be other broadcasts that landed after the cutoff
      # (reconcilers, observer state, etc). Just assert OUR event is
      # in there and nothing older than cutoff came through.
      assert Enum.any?(events, &String.contains?(&1.payload, id))
      assert Enum.all?(events, &(&1.inserted_at_ms > cutoff))
    end

    test "newest events come first" do
      # Emit one event with a unique id. Under concurrent tests,
      # another publisher may slip an event in between our broadcast
      # and the Tap.recent() call — so instead of asserting position
      # 0, find our event and assert that every event AFTER it in the
      # recent list has a LOWER seq (strictly descending ordering).
      id = "newest-#{System.unique_integer([:positive])}"

      Phoenix.PubSub.broadcast(
        Loopyard.PubSub,
        "chat_agents",
        {:chat_agent_renamed, id, "latest"}
      )

      Process.sleep(50)

      events = Tap.recent()

      assert Enum.any?(events, &String.contains?(&1.payload, id)),
             "published event not in Tap's recent buffer"

      seqs = Enum.map(events, & &1.seq)

      assert seqs == Enum.sort(seqs, :desc),
             "recent/0 must return events in strictly descending seq order"
    end
  end

  describe "topic_counts/0" do
    test "returns per-topic count of captured events" do
      # Take a baseline to avoid interference from other tests'
      # broadcasts that may have landed in the tap earlier in the run.
      before = Tap.topic_counts()

      Phoenix.PubSub.broadcast(Loopyard.PubSub, "chat_agents", {:chat_agent_started, %{}})
      Phoenix.PubSub.broadcast(Loopyard.PubSub, "chat_agents", {:chat_agent_stopped, %{}})
      Phoenix.PubSub.broadcast(Loopyard.PubSub, "docker_observer", {:docker_state_changed})
      Process.sleep(50)

      after_counts = Tap.topic_counts()
      assert Map.get(after_counts, "chat_agents", 0) - Map.get(before, "chat_agents", 0) >= 2

      assert Map.get(after_counts, "docker_observer", 0) - Map.get(before, "docker_observer", 0) >=
               1
    end
  end

  describe "payload truncation" do
    test "oversized payloads are truncated with a marker" do
      # Use a unique id so we can find OUR event among other tests'
      # broadcasts that are also landing in the tap concurrently.
      id = "truncate-oversized-#{System.unique_integer([:positive])}"
      big = String.duplicate("x", 5_000)

      Phoenix.PubSub.broadcast(
        Loopyard.PubSub,
        "chat_agents",
        {:chat_agent_started, %{id: id, blob: big}}
      )

      Process.sleep(50)

      event = find_event_by_id(id)
      assert String.ends_with?(event.payload, "…(truncated)")
      assert byte_size(event.payload) < 5_000
    end

    test "small payloads are NOT truncated" do
      id = "truncate-small-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.broadcast(Loopyard.PubSub, "chat_agents", {:chat_agent_started, %{id: id}})
      Process.sleep(50)

      event = find_event_by_id(id)
      refute String.ends_with?(event.payload, "…(truncated)")
    end
  end

  # Locate OUR broadcast among whatever else the tap has captured.
  defp find_event_by_id(id) do
    event = Enum.find(Tap.recent(), &String.contains?(&1.payload, id))
    assert event != nil, "expected a tap event containing #{inspect(id)}"
    event
  end
end
