defmodule Loopyard.ChatAgent.DeadSessionTest do
  @moduledoc """
  Coverage for the dead-session branch of `send_message_normal/2` in
  `lib/loopyard/chat_agent.ex` (the "your message didn't vanish on a
  CLI restart" guarantee — critical for phone use).

  When a `:send_message` arrives while `state.status` is `:idle`,
  ChatAgent runs `SessionManager.ensure_alive/1` and then re-checks
  `state.backend.session_alive?(state.session)`. If the session is
  STILL dead after the (re)spawn attempt, the branch must NOT silently
  drop the text back to idle. Instead it must:

    1. Append a `role: :error` message explaining the failure
       (WHY/CONSEQUENCE/ACTION).
    2. Queue the RAW text into `state.pending_sends` — nothing lost.
    3. Keep status `:idle`.
    4. Cast `:restart_session` to kick a reconnect.

  ## How the dead-session branch is forced

  Both the default Fake backend and RecordingBackend report
  `session_alive?` as `is_pid(session) and Process.alive?(session)`,
  so they can never drive this branch — any session they hand out is a
  live pid. We use a dedicated stub backend (`DeadBackend`, below)
  whose `session_alive?/1` ALWAYS returns `false`, while
  `start_session/1` still returns `{:ok, pid}` with a live pid. That
  models exactly the production failure mode: `ensure_alive/1`
  "successfully" spawns a CLI, but the freshly spawned session
  immediately reports dead, so the re-check after `ensure_alive/1`
  fails and we fall into the queue-and-error branch.

  We swap the backend in via `:sys.replace_state` AFTER the agent has
  booted on the default test backend — booting directly on DeadBackend
  would drive the agent's own init session-startup down a dead path,
  which is not what we're testing here.
  """

  use Loopyard.AgentCase

  alias Loopyard.ChatAgent
  alias Loopyard.ChatAgent.DeadSessionTest.CountingDeadBackend

  @moduletag timeout: 10_000

  # --- Stub backend that always reports the session as dead ---
  defmodule DeadBackend do
    @behaviour Loopyard.Harness

    @impl true
    def start_session(_opts) do
      # Hand back a live pid so `ensure_alive/1`'s start_session clause
      # takes the {:ok, _} path — yet session_alive? below still says
      # dead, so the re-check fails. This is the exact production shape:
      # spawn "succeeds" but the session is non-functional.
      Agent.start_link(fn -> :ok end)
    end

    @impl true
    def stream(_session, _prompt), do: []

    @impl true
    def stop(session) do
      if is_pid(session) and Process.alive?(session), do: Agent.stop(session, :normal)
      :ok
    end

    @impl true
    def session_alive?(_session), do: false

    @impl true
    def session_id(_session), do: nil
  end

  setup do
    id = "dead-session-test-#{:rand.uniform(1_000_000)}"

    {:ok, _pid} =
      Loopyard.TestHelpers.start_agent(
        id: id,
        name: "Dead Session Test",
        started_by: "test"
      )

    ChatAgent.subscribe(id)

    on_exit(fn ->
      try do
        ChatAgent.stop_agent(id)
      catch
        :exit, _ -> :ok
      end

      Process.sleep(20)
    end)

    %{id: id}
  end

  defp agent_pid(id) do
    case Registry.lookup(Loopyard.ChatAgentRegistry, id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  describe "send_message_normal dead-session branch (message-survival guarantee)" do
    test "queues raw text, drops a quiet note, reports BOOTING, and kicks restart", %{id: id} do
      pid = agent_pid(id)

      # Swap in the always-dead backend AFTER boot, and ensure status is
      # :idle so the send goes straight to send_message_normal (not the
      # :thinking/:backoff queue path of surface #15).
      :sys.replace_state(pid, fn s ->
        %{s | backend: DeadBackend, status: :idle, pending_sends: []}
      end)

      text = "this message must not vanish on a dead CLI"
      ChatAgent.send_message(id, text)
      Process.sleep(80)

      state = :sys.get_state(pid)

      # (2) RAW text queued — not dropped.
      assert text in state.pending_sends,
             "expected raw text queued in pending_sends, got: #{inspect(state.pending_sends)}"

      # (3) Status reports :booting — the harness is being respawned to take
      # this message. It used to stay :idle, which rendered as "Ready" in the
      # sidebar while the message sat "Queued" beneath it: a pair that is
      # indistinguishable from a wedged turn, and got reported as one. It is
      # not :thinking either — no turn has started.
      assert state.status == :booting

      # (1) SILENCE: the restart auto-fixes and auto-delivers, so there is NO
      # chat narration at all — the queue band + harness status carry it.
      # ("It either broke or it didn't" — self-healing never speaks.)
      refute Enum.any?(state.messages, &(&1.role in [:system, :error])),
             "dead-session send must be silent in chat (queue band + status carry it)"

      # The raw user text must NOT have been appended as a :user message
      # in this branch — it's only persisted as a user message once a
      # LIVE session finally accepts it (via drain_pending_sends ->
      # send_message_normal). Appending it here would double it later.
      refute Enum.any?(state.messages, &(&1.role == :user and &1.content == text)),
             "dead-session branch must not append the user message yet (would duplicate on drain)"
    end

    test "(4) :restart_session is cast: backend.start_session is invoked for reconnect",
         %{id: id} do
      pid = agent_pid(id)

      # Track start_session calls via a counting wrapper backend so we
      # can prove the :restart_session cast fired (it calls
      # backend.start_session). We use an ETS counter the backend bumps.
      test_pid = self()

      :sys.replace_state(pid, fn s ->
        %{s | backend: CountingDeadBackend, status: :idle, pending_sends: []}
      end)

      # Register where the counting backend should report starts.
      CountingDeadBackend.set_reporter(test_pid)

      ChatAgent.send_message(id, "kick the reconnect")

      # The dead-idle send takes the fast-ack path: queue the text + ONE async
      # :restart_session (which calls start_session). No synchronous
      # ensure_alive spawn in front anymore — the old double-start (probe
      # spawn + restart spawn) was both slow and wasteful.
      assert_receive {:dead_backend_start, _}, 1_000

      state = :sys.get_state(agent_pid(id))
      assert "kick the reconnect" in state.pending_sends
    end
  end

  # Counting variant of DeadBackend — reports each start_session call to
  # a test pid so we can prove the :restart_session cast fired.
  defmodule CountingDeadBackend do
    @behaviour Loopyard.Harness

    def set_reporter(pid), do: :persistent_term.put({__MODULE__, :reporter}, pid)
    defp reporter, do: :persistent_term.get({__MODULE__, :reporter}, nil)

    @impl true
    def start_session(_opts) do
      if p = reporter(), do: send(p, {:dead_backend_start, System.system_time()})
      Agent.start_link(fn -> :ok end)
    end

    @impl true
    def stream(_session, _prompt), do: []

    @impl true
    def stop(session) do
      if is_pid(session) and Process.alive?(session), do: Agent.stop(session, :normal)
      :ok
    end

    @impl true
    def session_alive?(_session), do: false

    @impl true
    def session_id(_session), do: nil
  end
end
