defmodule Loopyard.Harness.ACP.ConnectionTest do
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

  alias Loopyard.Harness.ACP.Connection
  alias Loopyard.Agent.Event

  # ---- fake transport ----

  defmodule FakeTransport do
    @moduledoc false
    @behaviour Loopyard.Harness.ACP.Transport
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

  # Start a Connection rooted at `cwd` and drive it to :ready. Used by the
  # fs clamp tests, which need a real on-disk cwd (handshake/1 below pins the
  # default "/workspace").
  defp ready_conn(cwd) do
    {conn, _transport} = start_conn(cwd: cwd)

    assert_receive {:sent, %{"method" => "initialize", "id" => init_id}}
    send(conn, {:acp_msg, %{"id" => init_id, "result" => %{}}})

    assert_receive {:sent, %{"method" => "session/new", "id" => new_id}}
    send(conn, {:acp_msg, %{"id" => new_id, "result" => %{"sessionId" => "sess-fs"}}})

    :ok = Connection.await_ready(conn, 1_000)
    conn
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
      {:acp_msg, %{"id" => new_id, "result" => %{"sessionId" => "sess-123", "models" => %{}}}}
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

    test "the prompt result's usage reaches SessionResult", %{conn: conn} do
      ref = make_ref()
      Connection.prompt(conn, "go", self(), ref)
      assert_receive {:sent, %{"method" => "session/prompt", "id" => id}}

      send(
        conn,
        {:acp_msg,
         %{
           "id" => id,
           "result" => %{
             "stopReason" => "end_turn",
             "usage" => %{
               "inputTokens" => 1_500,
               "outputTokens" => 320,
               "cachedReadTokens" => 90
             }
           }
         }}
      )

      assert_receive {:acp_event, ^ref,
                      %Event.SessionResult{
                        input_tokens: 1_500,
                        output_tokens: 320,
                        cache_read_tokens: 90
                      }}
    end
  end

  describe "cost accounting (cumulative → per-turn delta)" do
    setup do
      {conn, _transport} = start_conn()
      handshake(conn)
      {:ok, conn: conn}
    end

    # Drive one full turn, optionally pushing a cumulative cost mid-turn.
    # Returns the turn's SessionResult.
    defp turn_with_cost(conn, cumulative) do
      ref = make_ref()
      Connection.prompt(conn, "go", self(), ref)
      assert_receive {:sent, %{"method" => "session/prompt", "id" => id}}

      if cumulative do
        send(
          conn,
          {:acp_msg,
           notif("usage_update", %{
             "used" => 1_000,
             "size" => 200_000,
             "cost" => %{"amount" => cumulative, "currency" => "USD"}
           })}
        )
      end

      send(conn, {:acp_msg, %{"id" => id, "result" => %{"stopReason" => "end_turn"}}})
      assert_receive {:acp_event, ^ref, %Event.SessionResult{} = result}
      result
    end

    test "each turn reports only what it spent, not the running session total",
         %{conn: conn} do
      # The adapter passes through the SDK's total_cost_usd, which is CUMULATIVE.
      # StreamHandler adds cost_usd to a lifetime total, so reporting the
      # cumulative figure every turn would multiply spend by the turn count.
      assert turn_with_cost(conn, 0.10).cost_usd == 0.10
      assert_in_delta turn_with_cost(conn, 0.25).cost_usd, 0.15, 0.000001
      assert_in_delta turn_with_cost(conn, 0.30).cost_usd, 0.05, 0.000001
    end

    test "a counter reset (resume, /clear) is treated as a fresh delta, not zeros",
         %{conn: conn} do
      assert turn_with_cost(conn, 0.40).cost_usd == 0.40

      # Cumulative went DOWN — the session's counter restarted. Reporting
      # max(0, current - reported) would emit 0 until spend climbed back past
      # 0.40, silently losing every turn in between.
      assert turn_with_cost(conn, 0.05).cost_usd == 0.05
      assert_in_delta turn_with_cost(conn, 0.09).cost_usd, 0.04, 0.000001
    end

    test "a turn with no cost report costs nothing", %{conn: conn} do
      assert turn_with_cost(conn, nil).cost_usd == 0.0
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

    test "fs/read_text_file is answered with file content for an in-cwd path" do
      # handshake() above used cwd "/workspace"; for a real read we need a real
      # cwd. Start a fresh connection rooted at a tmp dir and write inside it.
      cwd = Path.join(System.tmp_dir!(), "acp_cwd_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(cwd)
      on_exit(fn -> File.rm_rf(cwd) end)

      conn = ready_conn(cwd)
      path = Path.join(cwd, "data.txt")
      File.write!(path, "VOLUME DATA")

      send(
        conn,
        {:acp_msg, %{"id" => 7, "method" => "fs/read_text_file", "params" => %{"path" => path}}}
      )

      assert_receive {:sent, %{"id" => 7, "result" => %{"content" => "VOLUME DATA"}}}
    end

    test "fs/read_text_file rejects a path that escapes the cwd root" do
      cwd = Path.join(System.tmp_dir!(), "acp_cwd_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(cwd)
      on_exit(fn -> File.rm_rf(cwd) end)

      conn = ready_conn(cwd)

      # Plant a secret OUTSIDE cwd; the adapter must not be able to read it.
      secret = Path.join(System.tmp_dir!(), "acp_secret_#{:erlang.unique_integer([:positive])}")
      File.write!(secret, "TOP SECRET")
      on_exit(fn -> File.rm(secret) end)

      # `..` traversal back out of cwd.
      escape = Path.join(cwd, "../" <> Path.basename(secret))

      send(
        conn,
        {:acp_msg, %{"id" => 8, "method" => "fs/read_text_file", "params" => %{"path" => escape}}}
      )

      assert_receive {:sent, %{"id" => 8, "error" => %{"code" => -32_602, "message" => msg}}}
      assert msg =~ "path outside workspace"
      refute_received {:sent, %{"id" => 8, "result" => _}}
    end

    test "fs/write_text_file rejects an absolute path outside the cwd root" do
      cwd = Path.join(System.tmp_dir!(), "acp_cwd_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(cwd)
      on_exit(fn -> File.rm_rf(cwd) end)

      conn = ready_conn(cwd)

      target = Path.join(System.tmp_dir!(), "acp_evil_#{:erlang.unique_integer([:positive])}")
      on_exit(fn -> File.rm(target) end)

      send(
        conn,
        {:acp_msg,
         %{
           "id" => 9,
           "method" => "fs/write_text_file",
           "params" => %{"path" => target, "content" => "owned"}
         }}
      )

      assert_receive {:sent, %{"id" => 9, "error" => %{"code" => -32_602}}}
      refute File.exists?(target)
    end
  end

  describe "AskUserQuestion via form elicitation" do
    setup do
      Loopyard.StateKeeper.ensure_tables!()
      :ok
    end

    test "advertises elicitation.form iff an agent_id is present" do
      {_conn, _t} = start_conn(agent_id: "elic-cap-agent")
      assert_receive {:sent, %{"method" => "initialize"} = frame}
      assert frame["params"]["clientCapabilities"]["elicitation"]["form"] == %{}
    end

    test "no elicitation capability without an agent_id" do
      {_conn, _t} = start_conn()
      assert_receive {:sent, %{"method" => "initialize"} = frame}
      refute Map.has_key?(frame["params"]["clientCapabilities"], "elicitation")
    end

    test "elicitation/create routes to the question broker; answer returns accept+content" do
      agent = "elic-agent-#{System.unique_integer([:positive])}"
      {conn, _t} = start_conn(agent_id: agent)
      handshake(conn)

      send(
        conn,
        {:acp_msg,
         %{
           "id" => 77,
           "method" => "elicitation/create",
           "params" => %{
             "mode" => "form",
             "sessionId" => "sess-123",
             "message" => "Deploy?",
             "requestedSchema" => %{
               "type" => "object",
               "properties" => %{
                 "question_0" => %{
                   "type" => "string",
                   "oneOf" => [%{"const" => "Yes"}, %{"const" => "No"}]
                 },
                 "question_0_custom" => %{"type" => "string", "title" => "Other"}
               }
             }
           }
         }}
      )

      # The blocked Task registered a pending question for this agent; a human
      # click resolves it and the connection answers the JSON-RPC request.
      qid = wait_for_agent_pending(agent)
      :ok = Loopyard.Harness.Questions.answer_partial(qid, "question_0", ["Yes"])

      assert_receive {:sent,
                      %{
                        "id" => 77,
                        "result" => %{"action" => "accept", "content" => %{"question_0" => "Yes"}}
                      }},
                     2_000
    end

    test "an unpresentable elicitation is declined (user-skipped), not cancelled" do
      {conn, _t} = start_conn(agent_id: "elic-decline-agent")
      handshake(conn)

      send(
        conn,
        {:acp_msg,
         %{"id" => 78, "method" => "elicitation/create", "params" => %{"mode" => "url"}}}
      )

      assert_receive {:sent, %{"id" => 78, "result" => %{"action" => "decline"}}}
    end
  end

  defp wait_for_agent_pending(agent, tries \\ 100) do
    case Loopyard.Harness.Questions.pending_for_agent(agent) do
      {qid, _entry} ->
        qid

      nil when tries > 0 ->
        Process.sleep(10)
        wait_for_agent_pending(agent, tries - 1)
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

  describe "model config-option dialect (claude-agent-acp 0.60+)" do
    # The renamed adapter dropped `models`/`session/set_model` from the wire:
    # models arrive as the `"model"` entry of `configOptions`, and switching is
    # `session/set_config_option`. Pre-fix, available_models parsed empty and
    # every model switch silently no-opped (observed live: an agent stuck on a
    # rate-limited Fable because set_model never reached the harness).

    defp config_options(current) do
      [
        %{"id" => "mode", "currentValue" => "default", "options" => []},
        %{
          "id" => "model",
          "currentValue" => current,
          "options" => [
            %{
              "value" => "claude-fable-5",
              "name" => "Fable 5",
              "description" => "Fable 5 · Most capable"
            },
            %{
              "value" => "claude-sonnet-5",
              "name" => "Sonnet 5",
              "description" => "Sonnet 5 · Everyday"
            }
          ]
        }
      ]
    end

    defp handshake_with_config_options(conn, current) do
      assert_receive {:sent, %{"method" => "initialize", "id" => init_id}}
      send(conn, {:acp_msg, %{"id" => init_id, "result" => %{}}})

      assert_receive {:sent, %{"method" => "session/new", "id" => new_id}}

      send(
        conn,
        {:acp_msg,
         %{
           "id" => new_id,
           "result" => %{"sessionId" => "sess-co", "configOptions" => config_options(current)}
         }}
      )

      :ok = Connection.await_ready(conn, 1_000)
    end

    test "session/new configOptions populate available_models and the current model name" do
      {conn, _transport} = start_conn(model: nil)
      handshake_with_config_options(conn, "claude-fable-5")

      assert [%{id: "claude-fable-5"}, %{id: "claude-sonnet-5"}] =
               Connection.available_models(conn)
    end

    test "desired model switch goes out as session/set_config_option" do
      {conn, _transport} = start_conn(model: "claude-sonnet-5")
      handshake_with_config_options(conn, "claude-fable-5")

      assert_receive {:sent, %{"method" => "session/set_config_option", "id" => _} = frame}
      assert frame["params"]["configId"] == "model"
      assert frame["params"]["value"] == "claude-sonnet-5"
      assert frame["params"]["sessionId"] == "sess-co"
    end

    test "live set_model uses session/set_config_option under the new dialect" do
      # model: nil → no boot-time auto-switch frame to confuse the assert.
      {conn, _transport} = start_conn(model: nil)
      handshake_with_config_options(conn, "claude-fable-5")

      Connection.set_model(conn, "claude-sonnet-5")

      assert_receive {:sent, %{"method" => "session/set_config_option"} = frame}
      assert frame["params"]["value"] == "claude-sonnet-5"
    end

    test "legacy models shape still uses session/set_model" do
      {conn, _transport} = start_conn(model: nil)

      assert_receive {:sent, %{"method" => "initialize", "id" => init_id}}
      send(conn, {:acp_msg, %{"id" => init_id, "result" => %{}}})
      assert_receive {:sent, %{"method" => "session/new", "id" => new_id}}

      send(
        conn,
        {:acp_msg,
         %{
           "id" => new_id,
           "result" => %{
             "sessionId" => "sess-legacy",
             "models" => %{
               "currentModelId" => "default",
               "availableModels" => [%{"modelId" => "opus", "name" => "Opus"}]
             }
           }
         }}
      )

      :ok = Connection.await_ready(conn, 1_000)
      Connection.set_model(conn, "opus")

      assert_receive {:sent, %{"method" => "session/set_model"} = frame}
      assert frame["params"]["modelId"] == "opus"
    end

    test "config_option_update notification retracks the current model" do
      {conn, _transport} = start_conn(model: nil)
      handshake_with_config_options(conn, "claude-fable-5")

      send(
        conn,
        {:acp_msg,
         %{
           "method" => "session/update",
           "params" => %{
             "update" => %{
               "sessionUpdate" => "config_option_update",
               "configOptions" => config_options("claude-sonnet-5")
             }
           }
         }}
      )

      # State reflects the pushed switch (poll via the public models call —
      # the cast is async).
      assert Connection.available_models(conn) != []
      state = :sys.get_state(conn)
      assert state.model == "Sonnet 5"
    end
  end

  describe "rate-limit classification" do
    # The claude-code-acp adapter doesn't surface an upstream rate-limit
    # rejection as a status — it errors the session/prompt request (and often
    # exits) with "API Error: Rate limit reached". Pre-fix, both read as
    # generic crashes: ChatAgent restart-with-resume looped straight back
    # into the hard limit (the death spiral). The Connection must classify
    # them and emit %Event.RateLimitStatus{status: :rejected} so the agent
    # parks in :rate_limited with a timed retry instead.

    test "session/prompt error mentioning a rate limit emits RateLimitStatus :rejected" do
      {conn, _transport} = start_conn()
      handshake(conn)
      ref = make_ref()
      Connection.prompt(conn, "go", self(), ref)
      assert_receive {:sent, %{"method" => "session/prompt", "id" => prompt_id}}

      send(
        conn,
        {:acp_msg,
         %{
           "id" => prompt_id,
           "error" => %{
             "code" => -32603,
             "message" => "Internal error: API Error: Rate limit reached"
           }
         }}
      )

      assert_receive {:acp_event, ^ref, %Event.RateLimitStatus{status: :rejected}}
      assert_receive {:acp_event, ^ref, %Event.SessionResult{}}
      assert_receive {:acp_done, ^ref, {:error, _}}
    end

    test "adapter death with rate-limit stderr emits RateLimitStatus before the error result" do
      stderr =
        Path.join(
          System.tmp_dir!(),
          "loopyard-acp-test-#{System.unique_integer([:positive])}.stderr"
        )

      File.write!(
        stderr,
        "Error handling request { method: 'session/prompt' } " <>
          "{ message: 'Internal error: API Error: Rate limit reached' }\ncontext canceled\n"
      )

      on_exit(fn -> File.rm(stderr) end)

      {conn, _transport} = start_conn(transport_opts: [test: self(), stderr_log: stderr])
      handshake(conn)
      ref = make_ref()
      Connection.prompt(conn, "go", self(), ref)
      assert_receive {:sent, %{"method" => "session/prompt"}}

      Process.flag(:trap_exit, true)
      send(conn, {:acp_closed, {:exit_status, 1}})

      assert_receive {:acp_event, ^ref, %Event.RateLimitStatus{status: :rejected}}
      assert_receive {:acp_done, ^ref, {:error, {:closed, {:exit_status, 1}}}}
    end

    test "adapter death with unrelated stderr does NOT emit RateLimitStatus" do
      stderr =
        Path.join(
          System.tmp_dir!(),
          "loopyard-acp-test-#{System.unique_integer([:positive])}.stderr"
        )

      File.write!(stderr, "context canceled\n")
      on_exit(fn -> File.rm(stderr) end)

      {conn, _transport} = start_conn(transport_opts: [test: self(), stderr_log: stderr])
      handshake(conn)
      ref = make_ref()
      Connection.prompt(conn, "go", self(), ref)
      assert_receive {:sent, %{"method" => "session/prompt"}}

      Process.flag(:trap_exit, true)
      send(conn, {:acp_closed, {:exit_status, 1}})

      assert_receive {:acp_done, ^ref, {:error, {:closed, {:exit_status, 1}}}}
      refute_received {:acp_event, ^ref, %Event.RateLimitStatus{}}
    end
  end

  describe "cancel (session/cancel)" do
    test "sends a session/cancel notification for the live session, keeping it warm" do
      {conn, _transport} = start_conn()
      sid = handshake(conn)

      Connection.cancel(conn)

      # A notification: has method + params, NO id (not a request).
      assert_receive {:sent, frame}
      assert frame["method"] == "session/cancel"
      assert frame["params"]["sessionId"] == sid
      refute Map.has_key?(frame, "id")

      # Connection is still alive and reports the same session.
      assert Connection.session_id(conn) == sid
    end

    test "no-op before a session exists" do
      {conn, _transport} = start_conn()
      # Still initializing — no session id yet.
      Connection.cancel(conn)
      refute_receive {:sent, %{"method" => "session/cancel"}}
    end
  end

  describe "resume (session/load)" do
    # Drive init, replying with the given agentCapabilities.
    defp init_with_caps(conn, caps) do
      assert_receive {:sent, %{"method" => "initialize", "id" => init_id}}
      send(conn, {:acp_msg, %{"id" => init_id, "result" => %{"agentCapabilities" => caps}}})
    end

    test "issues session/load with the saved id when the adapter supports it" do
      {conn, _transport} = start_conn(resume: "sess-prev")
      init_with_caps(conn, %{"loadSession" => true})

      assert_receive {:sent, %{"method" => "session/load", "id" => load_id} = frame}
      assert frame["params"]["sessionId"] == "sess-prev"
      refute_received {:sent, %{"method" => "session/new"}}

      send(conn, {:acp_msg, %{"id" => load_id, "result" => %{}}})
      assert Connection.await_ready(conn, 1_000) == :ok
      # Session id is the resumed one (load result omits it).
      assert Connection.session_id(conn) == "sess-prev"
    end

    test "falls back to session/new when the adapter can't load sessions" do
      {conn, _transport} = start_conn(resume: "sess-prev")
      init_with_caps(conn, %{"loadSession" => false})

      assert_receive {:sent, %{"method" => "session/new"}}
      refute_received {:sent, %{"method" => "session/load"}}
    end

    test "falls back to session/new when session/load errors (expired id)" do
      {conn, _transport} = start_conn(resume: "sess-gone")
      init_with_caps(conn, %{"loadSession" => true})

      assert_receive {:sent, %{"method" => "session/load", "id" => load_id}}

      send(
        conn,
        {:acp_msg,
         %{"id" => load_id, "error" => %{"code" => -32_000, "message" => "unknown session"}}}
      )

      # 2s: the load-error → session/new fallback does real work; the default
      # 100ms raced a loaded CI runner.
      assert_receive {:sent, %{"method" => "session/new", "id" => new_id}}, 2_000
      send(conn, {:acp_msg, %{"id" => new_id, "result" => %{"sessionId" => "sess-fresh"}}})
      assert Connection.await_ready(conn, 1_000) == :ok
      assert Connection.session_id(conn) == "sess-fresh"
    end

    test "no resume id → plain session/new (unchanged path)" do
      {conn, _transport} = start_conn()
      assert_receive {:sent, %{"method" => "initialize", "id" => init_id}}

      send(
        conn,
        {:acp_msg,
         %{"id" => init_id, "result" => %{"agentCapabilities" => %{"loadSession" => true}}}}
      )

      assert_receive {:sent, %{"method" => "session/new"}}
      refute_received {:sent, %{"method" => "session/load"}}
    end
  end

  # ---- helpers ----

  defp notif(kind, extra) do
    %{
      "method" => "session/update",
      "params" => %{"update" => Map.put(extra, "sessionUpdate", kind)}
    }
  end

  defp text(t), do: %{"type" => "text", "text" => t}
end
