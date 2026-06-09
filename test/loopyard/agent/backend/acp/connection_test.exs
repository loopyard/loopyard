defmodule Loopyard.Agent.Backend.ACP.ConnectionTest do
  use ExUnit.Case, async: true

  alias Loopyard.Agent.Backend.ACP.Connection
  alias Loopyard.Agent.Event
  alias Loopyard.Test.ACPFakeTransport, as: Fake

  # Manually-driven handshake (auto_handshake: false): the test plays the agent.
  defp start_manual do
    {:ok, conn} =
      Connection.start_link(
        transport: Fake,
        transport_opts: [test_pid: self()],
        cwd: "/tmp",
        model: "test-model"
      )

    assert_receive {:acp_sent, %{"method" => "initialize", "id" => init_id}}

    send(
      conn,
      {:acp_msg, %{"jsonrpc" => "2.0", "id" => init_id, "result" => %{"protocolVersion" => 1}}}
    )

    assert_receive {:acp_sent, %{"method" => "session/new", "id" => sn_id}}

    send(
      conn,
      {:acp_msg,
       %{
         "jsonrpc" => "2.0",
         "id" => sn_id,
         "result" => %{"sessionId" => "sess-1", "models" => %{"currentModelId" => "default"}}
       }}
    )

    assert :ok = Connection.await_ready(conn, 1_000)
    conn
  end

  defp update(kind, extra) do
    %{
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => %{"update" => Map.merge(%{"sessionUpdate" => kind}, extra)}
    }
  end

  test "completes the initialize -> session/new handshake and exposes session id" do
    conn = start_manual()
    assert Connection.session_id(conn) == "sess-1"
  end

  test "streams a prompt turn: deltas live, final Text + SessionResult on result" do
    conn = start_manual()
    ref = make_ref()
    Connection.prompt(conn, "hello", self(), ref)

    assert_receive {:acp_sent,
                    %{
                      "method" => "session/prompt",
                      "id" => p_id,
                      "params" => %{"sessionId" => "sess-1"}
                    }}

    send(
      conn,
      {:acp_msg,
       update("agent_message_chunk", %{"content" => %{"type" => "text", "text" => "Hi "}})}
    )

    send(
      conn,
      {:acp_msg,
       update("agent_message_chunk", %{"content" => %{"type" => "text", "text" => "there"}})}
    )

    assert_receive {:acp_event, ^ref, %Event.TextDelta{text: "Hi "}}
    assert_receive {:acp_event, ^ref, %Event.TextDelta{text: "there"}}

    send(
      conn,
      {:acp_msg, %{"jsonrpc" => "2.0", "id" => p_id, "result" => %{"stopReason" => "end_turn"}}}
    )

    assert_receive {:acp_event, ^ref, %Event.Text{text: "Hi there"}}
    # The model reported by the harness (session/new currentModelId) wins over
    # the opt — "default" here, not the "test-model" we passed in.
    assert_receive {:acp_event, ^ref, %Event.SessionResult{model: "default"}}
    assert_receive {:acp_done, ^ref, "end_turn"}
  end

  test "surfaces a PermissionRequest event and auto-allows" do
    conn = start_manual()
    ref = make_ref()
    Connection.prompt(conn, "go", self(), ref)
    assert_receive {:acp_sent, %{"method" => "session/prompt"}}

    send(
      conn,
      {:acp_msg,
       %{
         "jsonrpc" => "2.0",
         "id" => 99,
         "method" => "session/request_permission",
         "params" => %{
           "sessionId" => "sess-1",
           "toolCall" => %{
             "toolCallId" => "t1",
             "title" => "Write file",
             "rawInput" => %{"path" => "x"}
           },
           "options" => [
             %{"optionId" => "a", "name" => "Allow", "kind" => "allow_once"},
             %{"optionId" => "r", "name" => "Reject", "kind" => "reject_once"}
           ]
         }
       }}
    )

    assert_receive {:acp_event, ^ref, %Event.PermissionRequest{request_id: 99, options: opts}}
    assert Enum.any?(opts, &(&1.kind == "allow_once"))

    # And it auto-responds with the allow option so the turn proceeds.
    assert_receive {:acp_sent,
                    %{
                      "id" => 99,
                      "result" => %{"outcome" => %{"outcome" => "selected", "optionId" => "a"}}
                    }}
  end

  test "answers fs/read_text_file from disk" do
    conn = start_manual()
    path = Path.expand("mix.exs")

    send(
      conn,
      {:acp_msg,
       %{
         "jsonrpc" => "2.0",
         "id" => 77,
         "method" => "fs/read_text_file",
         "params" => %{"path" => path}
       }}
    )

    assert_receive {:acp_sent, %{"id" => 77, "result" => %{"content" => content}}}
    assert content =~ "defmodule Loopyard.MixProject"
  end
end
