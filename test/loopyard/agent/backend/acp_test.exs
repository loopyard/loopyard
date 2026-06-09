defmodule Loopyard.Agent.Backend.ACPTest do
  use ExUnit.Case, async: true

  alias Loopyard.Agent.Backend.ACP
  alias Loopyard.Agent.Event
  alias Loopyard.Test.ACPFakeTransport, as: Fake

  test "implements the Backend behaviour" do
    funcs = ACP.__info__(:functions)

    for f <- [start_session: 1, stream: 2, stop: 1, session_alive?: 1, session_id: 1] do
      assert f in funcs
    end
  end

  test "start_session completes the handshake and reports session id + liveness" do
    {:ok, conn} =
      ACP.start_session(
        transport: Fake,
        transport_opts: [test_pid: self(), auto_handshake: true],
        cwd: "/tmp"
      )

    assert ACP.session_alive?(conn)
    assert ACP.session_id(conn) == "sess-auto"
    assert ACP.stop(conn) == :ok
  end

  test "stream/2 yields translated events for a turn end to end" do
    {:ok, conn} =
      ACP.start_session(
        transport: Fake,
        transport_opts: [test_pid: self(), auto_handshake: true],
        cwd: "/tmp"
      )

    # Consume the stream in a task so we can inject agent traffic concurrently.
    task = Task.async(fn -> conn |> ACP.stream("hi") |> Enum.to_list() end)

    assert_receive {:acp_sent, %{"method" => "session/prompt", "id" => p_id}}, 2_000

    send(
      conn,
      {:acp_msg,
       %{
         "jsonrpc" => "2.0",
         "method" => "session/update",
         "params" => %{
           "update" => %{
             "sessionUpdate" => "agent_message_chunk",
             "content" => %{"type" => "text", "text" => "Hi"}
           }
         }
       }}
    )

    send(
      conn,
      {:acp_msg, %{"jsonrpc" => "2.0", "id" => p_id, "result" => %{"stopReason" => "end_turn"}}}
    )

    events = Task.await(task, 5_000)

    assert Enum.any?(events, &match?(%Event.TextDelta{text: "Hi"}, &1))
    assert Enum.any?(events, &match?(%Event.Text{text: "Hi"}, &1))
    assert match?(%Event.SessionResult{}, List.last(events))
  end
end
