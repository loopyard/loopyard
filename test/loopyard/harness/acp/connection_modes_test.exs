defmodule Loopyard.Harness.ACP.ConnectionModesTest do
  @moduledoc """
  Session modes on the Connection, against a fake transport (same contract as
  `ConnectionTest`'s): the handshake captures them, `set_mode/2` goes out on
  the wire and reverts on refusal, a `mode:` opt is re-applied to a fresh
  session, the harness's own mode changes are tracked, and — the point of the
  whole thing — Discuss keeps the harness planning when it asks to code.
  """
  use ExUnit.Case, async: true

  alias Loopyard.Harness.ACP.Connection

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
      send(test, {:transport_started, self(), Keyword.fetch!(opts, :owner)})
      {:ok, %{test: test}}
    end

    @impl GenServer
    def handle_cast({:send, message}, state) do
      send(state.test, {:sent, message})
      {:noreply, state}
    end
  end

  @modes %{
    "currentModeId" => "default",
    "availableModes" => [
      %{"id" => "default", "name" => "Manual", "description" => "Always ask"},
      %{"id" => "acceptEdits", "name" => "Accept edits", "description" => "Auto-accept"},
      %{"id" => "plan", "name" => "Plan", "description" => "Plan before changes"}
    ]
  }

  defp start_conn(opts \\ []) do
    base = [transport: FakeTransport, transport_opts: [test: self()], cwd: "/workspace"]
    {:ok, conn} = Connection.start_link(Keyword.merge(base, opts))
    assert_receive {:transport_started, _transport, ^conn}
    conn
  end

  # initialize → session/new → ready, with `result` merged into session/new's.
  defp handshake(conn, result \\ %{}) do
    assert_receive {:sent, %{"method" => "initialize", "id" => init_id}}
    send(conn, {:acp_msg, %{"id" => init_id, "result" => %{}}})

    assert_receive {:sent, %{"method" => "session/new", "id" => new_id}}

    send(
      conn,
      {:acp_msg, %{"id" => new_id, "result" => Map.merge(%{"sessionId" => "s-1"}, result)}}
    )

    :ok = Connection.await_ready(conn, 1_000)
  end

  defp update(conn, update),
    do:
      send(
        conn,
        {:acp_msg,
         %{"method" => "session/update", "params" => %{"sessionId" => "s-1", "update" => update}}}
      )

  describe "handshake" do
    test "captures the session's modes, the boot mode and the plan mode" do
      conn = start_conn()
      handshake(conn, %{"modes" => @modes})

      assert %{current: "default", boot: "default", plan: "plan", available: available} =
               Connection.modes(conn)

      assert [%{id: "default", name: "Manual"}, %{id: "acceptEdits"}, %{id: "plan"}] = available
    end

    test "a session without modes advertises no plan mode" do
      conn = start_conn()
      handshake(conn)

      assert %{current: nil, boot: nil, plan: nil, available: []} = Connection.modes(conn)
    end

    test "a `mode:` opt is applied once the session is ready (the Discuss setting survives a restart)" do
      conn = start_conn(mode: "plan")
      handshake(conn, %{"modes" => @modes})

      assert_receive {:sent, %{"method" => "session/set_mode", "params" => params}}
      assert params == %{"sessionId" => "s-1", "modeId" => "plan"}
      assert %{current: "plan", boot: "default"} = Connection.modes(conn)
    end

    test "a `mode:` opt the session does not advertise is left alone" do
      conn = start_conn(mode: "plan")
      handshake(conn)

      refute_receive {:sent, %{"method" => "session/set_mode"}}, 50
    end
  end

  # claude-agent-acp 0.108 boots a session in `auto` (a classifier decides
  # which tool calls run). Loopyard answers every permission request itself,
  # which is the `default` mode — the harness's home (Catalog `home_mode`).
  describe "home mode" do
    @auto_modes put_in(@modes["currentModeId"], "auto")
                |> update_in(["availableModes"], &(&1 ++ [%{"id" => "auto", "name" => "Auto"}]))

    test "a session that boots elsewhere is moved home, and home is what Build returns to" do
      conn = start_conn(home_mode: "default")
      handshake(conn, %{"modes" => @auto_modes})

      assert_receive {:sent, %{"method" => "session/set_mode", "params" => params}}
      assert params == %{"sessionId" => "s-1", "modeId" => "default"}
      assert %{current: "default", boot: "default", plan: "plan"} = Connection.modes(conn)
    end

    test "a session already home is left alone" do
      conn = start_conn(home_mode: "default")
      handshake(conn, %{"modes" => @modes})

      refute_receive {:sent, %{"method" => "session/set_mode"}}, 50
      assert %{current: "default", boot: "default"} = Connection.modes(conn)
    end

    test "Discuss wins over home, and Build still means home" do
      conn = start_conn(home_mode: "default", mode: "plan")
      handshake(conn, %{"modes" => @auto_modes})

      assert_receive {:sent, %{"method" => "session/set_mode", "params" => %{"modeId" => "plan"}}}
      assert %{current: "plan", boot: "default"} = Connection.modes(conn)
    end

    test "a home the session does not offer changes nothing; nor does having none" do
      conn = start_conn(home_mode: "manual")
      handshake(conn, %{"modes" => @auto_modes})
      refute_receive {:sent, %{"method" => "session/set_mode"}}, 50
      assert %{current: "auto", boot: "auto"} = Connection.modes(conn)

      conn = start_conn()
      handshake(conn, %{"modes" => @auto_modes})
      refute_receive {:sent, %{"method" => "session/set_mode"}}, 50
      assert %{current: "auto", boot: "auto"} = Connection.modes(conn)
    end
  end

  describe "set_mode/2" do
    test "sends session/set_mode and shows the new mode optimistically" do
      conn = start_conn()
      handshake(conn, %{"modes" => @modes})

      Connection.set_mode(conn, "plan")

      assert_receive {:sent, %{"method" => "session/set_mode", "id" => id, "params" => params}}
      assert params == %{"sessionId" => "s-1", "modeId" => "plan"}
      assert %{current: "plan"} = Connection.modes(conn)

      # The adapter confirms → nothing changes.
      send(conn, {:acp_msg, %{"id" => id, "result" => %{}}})
      assert %{current: "plan"} = Connection.modes(conn)
    end

    test "a refused switch reverts to the mode the session is actually in" do
      conn = start_conn()
      handshake(conn, %{"modes" => @modes})

      Connection.set_mode(conn, "plan")
      assert_receive {:sent, %{"method" => "session/set_mode", "id" => id}}

      send(conn, {:acp_msg, %{"id" => id, "error" => %{"code" => -32_602, "message" => "nope"}}})
      assert %{current: "default"} = Connection.modes(conn)
    end

    test "under the config-option dialect the switch is session/set_config_option" do
      conn = start_conn()

      handshake(conn, %{
        "configOptions" => [
          %{
            "id" => "mode",
            "category" => "mode",
            "currentValue" => "default",
            "options" => [
              %{"value" => "default", "name" => "Manual"},
              %{"value" => "plan", "name" => "Plan"}
            ]
          }
        ]
      })

      Connection.set_mode(conn, "plan")

      assert_receive {:sent, %{"method" => "session/set_config_option", "params" => params}}
      assert params == %{"sessionId" => "s-1", "configId" => "mode", "value" => "plan"}
    end
  end

  describe "harness-driven mode changes" do
    test "current_mode_update is tracked, with or without a turn" do
      conn = start_conn()
      handshake(conn, %{"modes" => @modes})

      update(conn, %{"sessionUpdate" => "current_mode_update", "currentModeId" => "plan"})
      assert %{current: "plan", boot: "default"} = Connection.modes(conn)
    end

    test "config_option_update carrying the mode option is tracked too" do
      conn = start_conn()
      handshake(conn, %{"modes" => @modes})

      update(conn, %{
        "sessionUpdate" => "config_option_update",
        "configOptions" => [
          %{
            "id" => "mode",
            "category" => "mode",
            "currentValue" => "acceptEdits",
            "options" => [
              %{"value" => "default", "name" => "Manual"},
              %{"value" => "acceptEdits", "name" => "Accept edits"}
            ]
          }
        ]
      })

      assert %{current: "acceptEdits"} = Connection.modes(conn)
    end
  end

  describe "Discuss keeps planning" do
    # ExitPlanMode reaches the client as a permission request whose tool call
    # is `kind: "switch_mode"`; the options are the adapter's real ones.
    @exit_plan %{
      "sessionId" => "s-1",
      "toolCall" => %{
        "toolCallId" => "tc-1",
        "title" => "Ready to code?",
        "kind" => "switch_mode",
        "rawInput" => %{"plan" => "1. Do the thing"}
      },
      "options" => [
        %{
          "optionId" => "exit-plan-default",
          "name" => "Yes, manually approve edits",
          "kind" => "allow_once"
        },
        %{
          "optionId" => "exit-plan-accept",
          "name" => "Yes, auto-accept edits",
          "kind" => "allow_always"
        },
        %{"optionId" => "reject", "name" => "No, keep planning", "kind" => "reject_once"}
      ]
    }

    defp request_permission(conn, params),
      do:
        send(
          conn,
          {:acp_msg, %{"id" => 77, "method" => "session/request_permission", "params" => params}}
        )

    test "while the human asked for Discuss, ExitPlanMode is answered 'keep planning'" do
      conn = start_conn()
      handshake(conn, %{"modes" => @modes})

      Connection.set_mode(conn, "plan")
      assert_receive {:sent, %{"method" => "session/set_mode"}}

      request_permission(conn, @exit_plan)

      assert_receive {:sent, %{"id" => 77, "result" => result}}
      assert result == %{"outcome" => %{"outcome" => "selected", "optionId" => "reject"}}
    end

    test "in Build, ExitPlanMode is allowed (the model entered plan mode on its own)" do
      conn = start_conn()
      handshake(conn, %{"modes" => @modes})

      # The harness went into plan mode by itself — no human asked for Discuss.
      update(conn, %{"sessionUpdate" => "current_mode_update", "currentModeId" => "plan"})

      request_permission(conn, @exit_plan)

      assert_receive {:sent, %{"id" => 77, "result" => result}}

      assert result == %{
               "outcome" => %{"outcome" => "selected", "optionId" => "exit-plan-default"}
             }
    end

    test "flipping back to Build before the request lands allows it" do
      conn = start_conn()
      handshake(conn, %{"modes" => @modes})

      Connection.set_mode(conn, "plan")
      assert_receive {:sent, %{"method" => "session/set_mode"}}
      Connection.set_mode(conn, "default")
      assert_receive {:sent, %{"method" => "session/set_mode"}}

      request_permission(conn, @exit_plan)

      assert_receive {:sent, %{"id" => 77, "result" => result}}

      assert result == %{
               "outcome" => %{"outcome" => "selected", "optionId" => "exit-plan-default"}
             }
    end

    test "an ordinary edit permission in Discuss is still auto-allowed (plan mode itself blocks edits)" do
      conn = start_conn()
      handshake(conn, %{"modes" => @modes})

      Connection.set_mode(conn, "plan")
      assert_receive {:sent, %{"method" => "session/set_mode"}}

      request_permission(conn, %{
        "sessionId" => "s-1",
        "toolCall" => %{"toolCallId" => "tc-2", "title" => "Edit foo.ex", "kind" => "edit"},
        "options" => [
          %{"optionId" => "allow", "name" => "Allow", "kind" => "allow_once"},
          %{"optionId" => "reject", "name" => "Reject", "kind" => "reject_once"}
        ]
      })

      assert_receive {:sent, %{"id" => 77, "result" => result}}
      assert result == %{"outcome" => %{"outcome" => "selected", "optionId" => "allow"}}
    end
  end
end
