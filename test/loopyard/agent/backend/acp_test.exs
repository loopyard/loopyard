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

  describe "in-container mode (#5)" do
    test "docker_exec_cmd builds the in-container command" do
      assert ACP.docker_exec_cmd("ctr") == "docker exec -i ctr claude-code-acp"

      assert ACP.docker_exec_cmd("ctr", "claude-agent-acp") ==
               "docker exec -i ctr claude-agent-acp"
    end

    test "container mode declares NO client fs capability and defaults cwd to /workspace" do
      {:ok, conn} =
        ACP.start_session(
          container: "c1",
          transport: Fake,
          transport_opts: [test_pid: self(), auto_handshake: true]
        )

      # No fs capability -> the in-container harness uses the container's own FS.
      assert_receive {:acp_sent,
                      %{"method" => "initialize", "params" => %{"clientCapabilities" => caps}}}

      assert caps == %{}

      assert_receive {:acp_sent,
                      %{"method" => "session/new", "params" => %{"cwd" => "/workspace"}}}

      ACP.stop(conn)
    end

    test "host mode advertises client fs capability" do
      {:ok, conn} =
        ACP.start_session(
          transport: Fake,
          transport_opts: [test_pid: self(), auto_handshake: true],
          cwd: "/tmp"
        )

      assert_receive {:acp_sent,
                      %{
                        "method" => "initialize",
                        "params" => %{"clientCapabilities" => %{"fs" => _}}
                      }}

      ACP.stop(conn)
    end
  end

  describe "system prompt install (#6)" do
    setup do
      dir = Path.join(System.tmp_dir!(), "acp-bsp-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "host mode installs the system prompt as CLAUDE.local.md", %{dir: dir} do
      {:ok, conn} =
        ACP.start_session(
          transport: Fake,
          transport_opts: [test_pid: self(), auto_handshake: true],
          cwd: dir,
          system_prompt: "You are a Loopyard agent. Be excellent."
        )

      assert File.read!(Path.join(dir, "CLAUDE.local.md")) =~ "You are a Loopyard agent"
      ACP.stop(conn)
    end

    test "container mode skips host filesystem install (targets the volume instead)", %{dir: dir} do
      {:ok, conn} =
        ACP.start_session(
          container: "c1",
          cwd: dir,
          transport: Fake,
          transport_opts: [test_pid: self(), auto_handshake: true],
          system_prompt: "x"
        )

      refute File.exists?(Path.join(dir, "CLAUDE.local.md"))
      ACP.stop(conn)
    end
  end
end
