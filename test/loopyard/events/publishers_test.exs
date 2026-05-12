defmodule Loopyard.Events.PublishersTest do
  @moduledoc """
  Unit tests for the publisher modules created in Move #2.

  Each test subscribes to the publisher's topic via the module's own
  `subscribe/0` (or `subscribe/1`) API, calls `publish/1` with the
  canonical struct, and asserts the struct round-trips unchanged.
  That's the full contract: `publish` actually broadcasts on the right
  topic, and the payload is untouched by the transport. If any of those
  invariants break, this test catches it before a subscriber has to.
  """

  # async: false — the freshly-created publisher modules
  # (`Loopyard.Events.*`) race with Elixir's parallel compiler
  # under full-suite load, producing flaky "module is not available"
  # errors on `Events.X.subscribe/0` calls. Serialized test
  # execution ensures the modules are fully loaded before any
  # test calls into them. See plans/post-migration-audit.md NOTE #14.
  use ExUnit.Case, async: false

  alias Loopyard.Events

  describe "ChatAgent publisher" do
    setup do
      Events.ChatAgent.subscribe()
      :ok
    end

    test "publish/1 broadcasts Started on chat_agents topic" do
      e = %Events.ChatAgent.Started{summary: %{id: "a1"}}
      Events.ChatAgent.publish(e)
      assert_receive ^e
    end

    test "publish/1 broadcasts Resumed" do
      e = %Events.ChatAgent.Resumed{summary: %{id: "a1"}}
      Events.ChatAgent.publish(e)
      assert_receive ^e
    end

    test "publish/1 broadcasts StatusChanged" do
      e = %Events.ChatAgent.StatusChanged{id: "a1", status: :idle}
      Events.ChatAgent.publish(e)
      assert_receive ^e
    end

    test "publish/1 rejects non-struct input" do
      assert_raise FunctionClauseError, fn ->
        Events.ChatAgent.publish({:chat_agent_started, %{}})
      end
    end

    test "events/0 lists every defined event module" do
      events = Events.ChatAgent.events()

      assert Events.ChatAgent.Started in events
      assert Events.ChatAgent.Resumed in events
      assert Events.ChatAgent.Quarantined in events
      assert Events.ChatAgent.Released in events
    end
  end

  describe "ChatAgentMessage publisher" do
    setup do
      agent_id = "agent-#{System.unique_integer([:positive])}"
      Events.ChatAgentMessage.subscribe(agent_id)
      {:ok, agent_id: agent_id}
    end

    test "publish/1 broadcasts Message on the agent-specific topic", %{agent_id: id} do
      e = %Events.ChatAgentMessage.Message{agent_id: id, msg: %{role: :user, content: "hi"}}
      Events.ChatAgentMessage.publish(e)
      assert_receive ^e
    end

    test "publish/1 of another agent's event does not leak to this subscription", %{agent_id: id} do
      other_id = "other-#{System.unique_integer([:positive])}"

      Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{
        agent_id: other_id,
        msg: %{role: :user, content: "not for me"}
      })

      refute_receive %Events.ChatAgentMessage.Message{agent_id: ^other_id}, 50
      _ = id
    end

    test "publish/1 broadcasts TextDelta", %{agent_id: id} do
      e = %Events.ChatAgentMessage.TextDelta{agent_id: id, text: "streaming..."}
      Events.ChatAgentMessage.publish(e)
      assert_receive ^e
    end

    test "publish/1 broadcasts StreamOutput", %{agent_id: id} do
      e = %Events.ChatAgentMessage.StreamOutput{
        agent_id: id,
        data: "out",
        title: "cmd",
        msg_id: "m1"
      }

      Events.ChatAgentMessage.publish(e)
      assert_receive ^e
    end
  end

  describe "DockerObserver publisher" do
    setup do
      Events.DockerObserver.subscribe()
      :ok
    end

    test "publish/1 broadcasts Changed" do
      Events.DockerObserver.publish(%Events.DockerObserver.Changed{})
      assert_receive %Events.DockerObserver.Changed{}
    end

    test "publish/1 broadcasts Reset, Disconnected, Reconnected" do
      Events.DockerObserver.publish(%Events.DockerObserver.Reset{})
      assert_receive %Events.DockerObserver.Reset{}

      Events.DockerObserver.publish(%Events.DockerObserver.Disconnected{})
      assert_receive %Events.DockerObserver.Disconnected{}

      Events.DockerObserver.publish(%Events.DockerObserver.Reconnected{})
      assert_receive %Events.DockerObserver.Reconnected{}
    end
  end

  describe "WorkspaceServices publisher" do
    setup do
      Events.WorkspaceServices.subscribe()
      :ok
    end

    test "publish/1 broadcasts ServicesUpdated" do
      e = %Events.WorkspaceServices.ServicesUpdated{path: "/some/path"}
      Events.WorkspaceServices.publish(e)
      assert_receive ^e
    end

    test "publish/1 broadcasts ComposeResult" do
      e = %Events.WorkspaceServices.ComposeResult{workspace_id: "ws1", result: :ok}
      Events.WorkspaceServices.publish(e)
      assert_receive ^e
    end
  end

  describe "SourceSync publisher" do
    test "publish/1 broadcasts Updated on the workspace-specific topic" do
      ws_id = "ws-#{System.unique_integer([:positive])}"
      Events.SourceSync.subscribe(ws_id)

      e = %Events.SourceSync.Updated{workspace_id: ws_id, status: %{status: :running}}
      Events.SourceSync.publish(e)

      assert_receive ^e
    end

    test "cross-workspace isolation" do
      mine = "mine-#{System.unique_integer([:positive])}"
      other = "other-#{System.unique_integer([:positive])}"
      Events.SourceSync.subscribe(mine)

      Events.SourceSync.publish(%Events.SourceSync.Updated{
        workspace_id: other,
        status: %{status: :paused}
      })

      refute_receive %Events.SourceSync.Updated{workspace_id: ^other}, 50
    end
  end

  describe "Terminal publisher" do
    test "publish/1 broadcasts Output on the container-specific topic" do
      container = "term-#{System.unique_integer([:positive])}"
      Events.Terminal.subscribe(container)

      e = %Events.Terminal.Output{container: container, data: "hello"}
      Events.Terminal.publish(e)

      assert_receive ^e
    end

    test "publish/1 broadcasts Clear and Exit" do
      container = "term-#{System.unique_integer([:positive])}"
      Events.Terminal.subscribe(container)

      Events.Terminal.publish(%Events.Terminal.Clear{container: container})
      assert_receive %Events.Terminal.Clear{container: ^container}

      Events.Terminal.publish(%Events.Terminal.Exit{container: container, code: 0})
      assert_receive %Events.Terminal.Exit{container: ^container, code: 0}
    end
  end

  describe "IexSession publisher" do
    test "publish/1 broadcasts Changed" do
      Events.IexSession.subscribe()
      e = %Events.IexSession.Changed{state: %{level: :green}}
      Events.IexSession.publish(e)
      assert_receive ^e
    end
  end

  describe "Telemetry" do
    test "every publish emits [:loopyard, :events, :publish]" do
      test_pid = self()
      ref = make_ref()
      # Use a unique handler id so cleanup only targets OUR handler.
      # The previous implementation did
      # `telemetry.list_handlers([]) |> Enum.each(detach)` which
      # detached EVERY handler in the system — including the Saga
      # Recorder and Checkpointer — causing those subsystems to
      # silently stop recording for the rest of the test run.
      handler_id = "test-publishers-telemetry-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:loopyard, :events, :publish],
        fn _event, measurements, meta, _ ->
          send(test_pid, {ref, measurements, meta})
        end,
        nil
      )

      try do
        Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: "a1", status: :idle})

        assert_receive {^ref, %{count: 1},
                        %{topic: "chat_agents", event: Events.ChatAgent.StatusChanged}}
      after
        :telemetry.detach(handler_id)
      end
    end
  end
end
