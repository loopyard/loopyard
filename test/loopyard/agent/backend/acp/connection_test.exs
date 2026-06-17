defmodule Loopyard.Agent.Backend.ACP.ConnectionTest do
  @moduledoc """
  Connection tests against a FAKE transport — no Port, no subprocess.

  The Connection accepts an injectable `:transport` module (connection.ex
  `init/1`). Our fake implements the `Transport` behaviour contract:

    * `start_link/1` — captures `:owner` (the Connection pid) and a
      `:test` pid it forwards every outbound frame to as `{:sent, msg}`.
    * `send_msg/2` — records the outbound JSON-RPC frame.

  Inbound frames are injected by sending the Connection the same messages
  a real transport would (`{:acp_msg, map}` / `{:acp_closed, reason}`),
  exactly as `Transport.Port` does. The fake registers itself so the test
  can grab the transport pid if needed, but inbound injection goes straight
  to the Connection (we know its pid).
  """
  use ExUnit.Case, async: true

  alias Loopyard.Agent.Backend.ACP.Connection
  alias Loopyard.Agent.Event

  # ---- fake transport ----

  defmodule FakeTransport do
    @moduledoc false
    @behaviour Loopyard.Agent.Backend.ACP.Transport
    use GenServer

    @impl true
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def send_msg(pid, message), do: GenServer.cast(pid, {:send, message})

    @impl true
    def close(pid), do: GenServer.stop(pid, :normal)

    @impl GenServer
    def init(opts) do
      test = Keyword.fetch!(opts, :test)
      owner = Keyword.fetch!(opts, :owner)
      # Tell the test which transport pid was created (and the owner conn).
      send(test, {:transport_started, self(), owner})
      {:ok, %{test: test, owner: owner}}
    end

    @impl GenServer
    def handle_cast({:send, message}, state) do
      send(state.test, {:sent, message})
      {:noreply, state}
    end
  end

  # Spawn a Connection wired to FakeTransport; returns {conn, transport}.
  defp start_conn(opts \\ []) do
    base = [
      transport: FakeTransport,
      transport_opts: [test: self()],
      cwd: "/workspace",
      model: "claude-x"
    ]

    {:ok, conn} = Connection.start_link(Keyword.merge(base, opts))

    assert_receive {:transport_started, transport, ^conn}
    {conn, transport}
  end

  # Drive the handshake to :ready, returning the session id used.
  defp handshake(conn) do
    # Connection sent "initialize" on init.
    assert_receive {:sent, %{"method" => "initialize", "id" => init_id} = init_frame}
    assert init_frame["params"]["protocolVersion"] == 1
    assert init_frame["params"]["clientCapabilities"]["fs"]["readTextFile"] == true

    # Reply to initialize → Connection sends session/new.
    send(conn, {:acp_msg, %{"id" => init_id, "result" => %{}}})

    assert_receive {:sent, %{"method" => "session/new", "id" => new_id} = new_frame}
    assert new_frame["params"]["cwd"] == "/workspace"

    # Reply to session/new with a session id → status becomes :ready.
    send(
      conn,
      {:acp_msg,
       %{"id" => new_id, "result" => %{"sessionId" => "sess-123", "models" => %{}}}}
    )

    :ok = Connection.await_ready(conn, 1_000)
    "sess-123"
  end

  describe "handshake" do
    test "initialize -> session/new -> ready, capturing the session id" do
      {conn, _transport} = start_conn()
      handshake(conn)

      assert Connection.session_id(conn) == "sess-123"
    end

    test "client declares NO fs capability when client_fs: false (in-container)" do
      {_conn, _transport} = start_conn(client_fs: false)

      assert_receive {:sent, %{"method" => "initialize"} = frame}
      assert frame["params"]["clientCapabilities"] == %{}
    end

    test "session/new error surfaces to a parked await_ready waiter" do
      {conn, _transport} = start_conn()

      assert_receive {:sent, %{"method" => "initialize", "id" => init_id}}
      send(conn, {:acp_msg, %{"id" => init_id, "result" => %{}}})

      assert_receive {:sent, %{"method" => "session/new", "id" => new_id}}

      # Park a waiter BEFORE the error arrives so it receives the original
      # error (a waiter that arrives after :closed just gets {:error, :closed}).
      task = Task.async(fn -> Connection.await_ready(conn, 1_000) end)
      Process.sleep(20)

      send(conn, {:acp_msg, %{"id" => new_id, "error" => %{"message" => "nope"}}})

      assert {:error, %{"message" => "nope"}} = Task.await(task, 1_000)
    end
  end

  describe "prompt turn" do
    setup do
      {conn, _transport} = start_conn()
      handshake(conn)
      {:ok, conn: conn}
    end

    test "session/prompt sends the right frame and streams session/update events",
         %{conn: conn} do
      ref = make_ref()
      Connection.prompt(conn, "do the thing", self(), ref)

      # The prompt frame goes out with our text and the session id.
      assert_receive {:sent, %{"method" => "session/prompt", "id" => prompt_id} = frame}
      assert frame["params"]["sessionId"] == "sess-123"
      assert frame["params"]["prompt"] == [%{"type" => "text", "text" => "do the thing"}]

      # Stream a text delta as a session/update notification (no id).
      send(conn, {:acp_msg, notif("agent_message_chunk", %{"content" => text("hi")})})
      assert_receive {:acp_event, ^ref, %Event.TextDelta{text: "hi"}}

      # Stream a tool call (input present → emits immediately).
      send(
        conn,
        {:acp_msg,
         notif("tool_call", %{
           "toolCallId" => "t1",
           "title" => "Read",
           "rawInput" => %{"path" => "/a"}
         })}
      )

      assert_receive {:acp_event, ^ref, %Event.ToolCall{id: "t1", name: "Read"}}

      # Resolve the prompt → finish emits Text + SessionResult, then done.
      send(conn, {:acp_msg, %{"id" => prompt_id, "result" => %{"stopReason" => "end_turn"}}})

      assert_receive {:acp_event, ^ref, %Event.Text{text: "hi"}}
      assert_receive {:acp_event, ^ref, %Event.SessionResult{model: "claude-x"}}
      assert_receive {:acp_done, ^ref, "end_turn"}
    end

    test "session/update notifications are ignored when no turn is active",
         %{conn: conn} do
      # No prompt in flight; a stray notification must not crash or emit.
      send(conn, {:acp_msg, notif("agent_message_chunk", %{"content" => text("ghost")})})
      refute_receive {:acp_event, _ref, _event}, 100
      assert Process.alive?(conn)
    end
  end

  describe "agent-initiated requests" do
    setup do
      {conn, _transport} = start_conn()
      handshake(conn)
      {:ok, conn: conn}
    end

    test "auto-allow permission picks an allow option and surfaces a PermissionRequest",
         %{conn: conn} do
      ref = make_ref()
      Connection.prompt(conn, "go", self(), ref)
      assert_receive {:sent, %{"method" => "session/prompt"}}

      # Agent asks for permission (has an "id" + "method").
      send(
        conn,
        {:acp_msg,
         %{
           "id" => 99,
           "method" => "session/request_permission",
           "params" => %{
             "sessionId" => "sess-123",
             "toolCall" => %{"toolCallId" => "t1", "title" => "Bash"},
             "options" => [
               %{"optionId" => "deny-1", "name" => "Deny", "kind" => "reject_once"},
               %{"optionId" => "allow-1", "name" => "Allow", "kind" => "allow_once"}
             ]
           }
         }}
      )

      # Surfaced to the turn subscriber for the future UI.
      assert_receive {:acp_event, ^ref, %Event.PermissionRequest{request_id: 99}}

      # Responded auto-allow: selects the option whose kind starts with "allow".
      assert_receive {:sent, %{"id" => 99, "result" => result}}
      assert result["outcome"] == %{"outcome" => "selected", "optionId" => "allow-1"}
    end

    test "fs/read_text_file is answered with file content", %{conn: conn} do
      path = Path.join(System.tmp_dir!(), "acp_conn_read_#{:erlang.unique_integer([:positive])}")
      File.write!(path, "VOLUME DATA")
      on_exit(fn -> File.rm(path) end)

      send(
        conn,
        {:acp_msg,
         %{"id" => 7, "method" => "fs/read_text_file", "params" => %{"path" => path}}}
      )

      assert_receive {:sent, %{"id" => 7, "result" => %{"content" => "VOLUME DATA"}}}
    end
  end

  describe "transport close" do
    test "{:acp_closed, reason} fails an in-flight turn and stops the connection" do
      {conn, _transport} = start_conn()
      handshake(conn)
      ref = make_ref()
      Connection.prompt(conn, "go", self(), ref)
      assert_receive {:sent, %{"method" => "session/prompt"}}

      Process.flag(:trap_exit, true)
      send(conn, {:acp_closed, {:exit_status, 1}})

      assert_receive {:acp_done, ^ref, {:error, {:closed, {:exit_status, 1}}}}
      assert_receive {:EXIT, ^conn, :normal}
    end

    test "{:acp_closed, reason} before ready fails await_ready waiters" do
      {conn, _transport} = start_conn()
      # Don't complete the handshake; a waiter is parked.
      Process.flag(:trap_exit, true)

      task = Task.async(fn -> Connection.await_ready(conn, 1_000) end)
      # Give the waiter time to register, then close the transport.
      Process.sleep(20)
      send(conn, {:acp_closed, :boom})

      assert {:error, {:closed, :boom}} = Task.await(task, 1_000)
      assert_receive {:EXIT, ^conn, :normal}
    end
  end

  # ---- helpers ----

  defp notif(kind, extra) do
    %{"method" => "session/update", "params" => %{"update" => Map.put(extra, "sessionUpdate", kind)}}
  end

  defp text(t), do: %{"type" => "text", "text" => t}
end
