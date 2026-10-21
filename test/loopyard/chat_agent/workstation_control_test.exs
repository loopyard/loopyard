defmodule Loopyard.ChatAgent.WorkstationControlTest do
  @moduledoc """
  The per-agent ACCOUNT (`workstation_identity`): stamped at boot, persisted
  across a server-restart resume, switchable from the picker — and the switch
  is a `:credentials` restart: the harness relaunches under the new identity
  with the native session id DROPPED (the new account can't see the old
  session), the conversation rebuilt from Loopyard's log.
  """
  use Loopyard.AgentCase

  alias Loopyard.ChatAgent
  alias Loopyard.ChatAgent.WorkstationControl
  alias Loopyard.TestSupport.RecordingBackend
  alias Loopyard.Workstation

  @moduletag timeout: 10_000

  setup do
    RecordingBackend.reset()
    Application.put_env(:loopyard, :crash_backoff_base_ms, 0)
    on_exit(fn -> Application.delete_env(:loopyard, :crash_backoff_base_ms) end)

    # A second workstation to move onto. Removed afterwards: a lingering dir is
    # a real identity bootstrap may adopt as `current` (see EnvSyncHomeTest).
    other = "acct-#{System.unique_integer([:positive])}"
    :ok = Workstation.create(other)
    on_exit(fn -> File.rm_rf(Workstation.dir(other)) end)

    id = "wsctl-#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      Loopyard.TestHelpers.start_agent(
        id: id,
        name: "Account Test",
        started_by: "test",
        backend: RecordingBackend,
        workstation_identity: "rocketship"
      )

    ChatAgent.subscribe()
    ChatAgent.subscribe(id)

    on_exit(fn ->
      try do
        ChatAgent.stop_agent(id)
      catch
        :exit, _ -> :ok
      end

      Process.sleep(20)
    end)

    %{id: id, other: other}
  end

  defp agent_pid(id) do
    case Registry.lookup(Loopyard.ChatAgentRegistry, id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  describe "the stamp" do
    test "an explicit identity rides state, the summary row and the session opts",
         %{id: id} do
      state = :sys.get_state(agent_pid(id))
      assert state.workstation_identity == "rocketship"

      [{^id, summary}] = :ets.lookup(:chat_agents, id)
      assert summary.workstation_identity == "rocketship"

      # What the harness launch reads (Harness.ACP sources env.<identity>).
      [opts | _] = RecordingBackend.starts()
      assert Keyword.get(opts, :workstation_identity) == "rocketship"
    end

    test "survives a server-restart resume", %{id: id} do
      pid = agent_pid(id)
      live = :sys.get_state(pid)

      # What ServiceManager replays after a Loopyard restart: the persisted
      # summary (with the stamp) → a fresh GenServer with resume: true.
      :ets.insert(:chat_agents, {id, ChatAgent.summary(live)})
      ChatAgent.stop_agent(id)
      Process.sleep(50)
      RecordingBackend.reset()

      {:ok, _} =
        Loopyard.TestHelpers.start_agent(
          id: id,
          name: "Account Test",
          started_by: "test",
          backend: RecordingBackend,
          resume: true
        )

      assert :sys.get_state(agent_pid(id)).workstation_identity == "rocketship"
      [opts | _] = RecordingBackend.starts()
      assert Keyword.get(opts, :workstation_identity) == "rocketship"
    end
  end

  describe "set_workstation/2" do
    test "re-stamps the agent and runs a :credentials restart under the new account",
         %{id: id, other: other} do
      pid = agent_pid(id)
      # A captured native session: the switch must NOT resume it.
      :sys.replace_state(pid, &Map.put(&1, :claude_session_id, "sess-old-account"))
      RecordingBackend.reset()

      ChatAgent.set_workstation(id, other)

      # "Reconnecting" in the sidebar while it happens, then back to Ready.
      assert_receive %Loopyard.Events.ChatAgent.StatusChanged{id: ^id, status: :backoff}, 1_000
      assert_receive %Loopyard.Events.ChatAgent.StatusChanged{id: ^id, status: :idle}, 1_000

      state = :sys.get_state(pid)
      assert state.workstation_identity == other
      assert Keyword.get(state.session_opts, :workstation_identity) == other
      # A later "Restart agent" (reload) rebuilds from these — must not revert.
      assert Keyword.get(state.init_opts, :workstation_identity) == other

      [{^id, summary}] = :ets.lookup(:chat_agents, id)
      assert summary.workstation_identity == other

      [opts] = RecordingBackend.starts()
      assert Keyword.get(opts, :workstation_identity) == other

      refute Keyword.has_key?(opts, :resume),
             "the new account can't see the old session — it must be rebuilt, not resumed"

      # No chat line: the harness-status block carries the transient state.
      refute Enum.any?(ChatAgent.summary(state).messages, &(&1[:role] == :system))
    end

    test "picking the account the agent is already on is a no-op", %{id: id} do
      pid = agent_pid(id)
      RecordingBackend.reset()

      ChatAgent.set_workstation(id, "rocketship")
      :sys.get_state(pid)

      assert RecordingBackend.starts() == []
    end

    test "an unknown workstation is refused", %{id: id} do
      pid = agent_pid(id)
      RecordingBackend.reset()

      ChatAgent.set_workstation(id, "no-such-ws-#{System.unique_integer([:positive])}")
      state = :sys.get_state(pid)

      assert state.workstation_identity == "rocketship"
      assert RecordingBackend.starts() == []
    end

    test "a system agent's identity is where it lives — not switchable", %{other: other} do
      state = %{id: "sys", name: "op", scope: :system, workstation_identity: "brad"}
      assert {^state, {:error, :system_agent}} = WorkstationControl.switch(state, other)
    end
  end

  describe "Workstation.reload_agents/1" do
    test "restarts the agents stamped with that identity, and only those",
         %{id: id, other: other} do
      pid = agent_pid(id)
      RecordingBackend.reset()

      # The agent is on "rocketship"; a push to `other` must leave it alone…
      Workstation.reload_agents(other)
      :sys.get_state(pid)
      assert RecordingBackend.starts() == []

      # …and a push to its own account restarts it.
      Workstation.reload_agents("rocketship")
      assert_receive %Loopyard.Events.ChatAgent.StatusChanged{id: ^id, status: :idle}, 1_000
      assert [_] = RecordingBackend.starts()
    end
  end
end
