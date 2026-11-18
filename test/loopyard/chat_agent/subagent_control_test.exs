defmodule Loopyard.ChatAgent.SubagentControlTest do
  @moduledoc """
  The per-agent SUB-AGENT model (`session_opts[:subagent_model]`): rides the
  summary row and the persisted `{:agent, …}` record, survives a server-restart
  resume AND a "Restart agent" (`:reload`) rebuild, and a change relaunches the
  harness with the conversation RESUMED (same harness, same account — the
  native session id is kept), never mid-turn.
  """
  use Loopyard.AgentCase

  alias Loopyard.ChatAgent
  alias Loopyard.ChatAgent.SubagentControl
  alias Loopyard.TestSupport.RecordingBackend

  @moduletag timeout: 10_000

  setup do
    RecordingBackend.reset()
    Application.put_env(:loopyard, :crash_backoff_base_ms, 0)
    on_exit(fn -> Application.delete_env(:loopyard, :crash_backoff_base_ms) end)

    id = "subctl-#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      Loopyard.TestHelpers.start_agent(
        id: id,
        name: "Sub-agent Test",
        started_by: "test",
        backend: RecordingBackend
      )

    ChatAgent.subscribe()

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
    [{pid, _}] = Registry.lookup(Loopyard.ChatAgentRegistry, id)
    pid
  end

  # "Reconnecting…" (:backoff) then Ready (:idle) — and drop every other
  # status broadcast so a later assert_receive can't match a stale one.
  defp set_and_settle(id, model) do
    ChatAgent.set_subagent_model(id, model)
    assert_receive %Loopyard.Events.ChatAgent.StatusChanged{id: ^id, status: :backoff}, 1_000
    assert_receive %Loopyard.Events.ChatAgent.StatusChanged{id: ^id, status: :idle}, 1_000
    state = :sys.get_state(agent_pid(id))
    flush_status(id)
    state
  end

  defp flush_status(id) do
    receive do
      %Loopyard.Events.ChatAgent.StatusChanged{id: ^id} -> flush_status(id)
    after
      0 -> :ok
    end
  end

  # The log append goes through the workspace Checkpointer (a cast), so poll.
  defp eventually_logged?(path, id, fun, tries \\ 50) do
    {:ok, entries} = Loopyard.AgentLog.read_events(log_path: path)

    cond do
      Enum.any?(entries, &(match?({:agent, ^id, _}, &1) and fun.(elem(&1, 2)))) -> true
      tries == 0 -> false
      true -> Process.sleep(20) && eventually_logged?(path, id, fun, tries - 1)
    end
  end

  test "defaults to nil — same as the agent — and launches nothing extra", %{id: id} do
    [{^id, summary}] = :ets.lookup(:chat_agents, id)
    assert summary.subagent_model == nil
    [opts | _] = RecordingBackend.starts()
    refute Keyword.has_key?(opts, :subagent_model)
  end

  test "a change persists on state, the summary and the log record, and relaunches RESUMED",
       %{id: id} do
    pid = agent_pid(id)
    :sys.replace_state(pid, &Map.put(&1, :claude_session_id, "sess-keep"))
    RecordingBackend.reset()

    state = set_and_settle(id, "haiku")

    assert Keyword.get(state.session_opts, :subagent_model) == "haiku"
    [{^id, summary}] = :ets.lookup(:chat_agents, id)
    assert summary.subagent_model == "haiku"

    # The persisted `{:agent, …}` record is the summary minus messages.
    path = Loopyard.ChatAgent.Persistence.log_path_for(state)
    assert is_binary(path)
    assert eventually_logged?(path, id, &(&1[:subagent_model] == "haiku"))

    [opts] = RecordingBackend.starts()
    assert Keyword.get(opts, :subagent_model) == "haiku"
    assert Keyword.get(opts, :resume) == "sess-keep", "same harness + account → resume"

    # Silent: no chat line for a deliberate setting change.
    refute Enum.any?(ChatAgent.summary(state).messages, &(&1[:role] == :system))
  end

  test "survives a full Restart agent (:reload) — the rebuild must not revert it", %{id: id} do
    set_and_settle(id, "sonnet")
    RecordingBackend.reset()

    ChatAgent.restart_session(id, :reload)
    assert_receive %Loopyard.Events.ChatAgent.StatusChanged{id: ^id, status: :idle}, 1_000

    state = :sys.get_state(agent_pid(id))
    assert Keyword.get(state.session_opts, :subagent_model) == "sonnet"
    [opts] = RecordingBackend.starts()
    assert Keyword.get(opts, :subagent_model) == "sonnet"
  end

  test "clearing it survives a :reload too (the boot opts must not restore it)", %{id: id} do
    set_and_settle(id, "sonnet")
    set_and_settle(id, "")
    RecordingBackend.reset()

    ChatAgent.restart_session(id, :reload)
    assert_receive %Loopyard.Events.ChatAgent.StatusChanged{id: ^id, status: :idle}, 1_000

    [opts] = RecordingBackend.starts()
    refute Keyword.has_key?(opts, :subagent_model)
  end

  test "survives a server-restart resume", %{id: id} do
    state = set_and_settle(id, "sonnet")
    :ets.insert(:chat_agents, {id, ChatAgent.summary(state)})
    ChatAgent.stop_agent(id)
    Process.sleep(50)
    RecordingBackend.reset()

    {:ok, _} =
      Loopyard.TestHelpers.start_agent(
        id: id,
        name: "Sub-agent Test",
        started_by: "test",
        backend: RecordingBackend,
        resume: true
      )

    [{^id, summary}] = :ets.lookup(:chat_agents, id)
    assert summary.subagent_model == "sonnet"
    [opts | _] = RecordingBackend.starts()
    assert Keyword.get(opts, :subagent_model) == "sonnet"
  end

  test "the harness and the model survive a server-restart resume too", %{id: id} do
    state = :sys.get_state(agent_pid(id))
    summary = %{ChatAgent.summary(state) | harness: :codex, model: "Sonnet 5"}
    :ets.insert(:chat_agents, {id, summary})
    ChatAgent.stop_agent(id)
    Process.sleep(50)
    RecordingBackend.reset()

    {:ok, _} =
      Loopyard.TestHelpers.start_agent(
        id: id,
        name: "Sub-agent Test",
        started_by: "test",
        backend: RecordingBackend,
        resume: true
      )

    # The boot opts are what start_session chooses the adapter from (and what a
    # later "Restart agent" rebuilds from).
    opts = :sys.get_state(agent_pid(id)).init_opts
    # It was on Codex; it must not come back as the default harness.
    assert Keyword.get(opts, :harness) == :codex
    # Codex pins no model list, so a Claude label is not handed to it.
    refute Keyword.has_key?(opts, :model)
  end

  test "a Claude agent's model comes back by id, from the label the row shows", %{id: id} do
    state = :sys.get_state(agent_pid(id))
    summary = %{ChatAgent.summary(state) | harness: :claude, model: "Sonnet 5"}
    :ets.insert(:chat_agents, {id, summary})
    ChatAgent.stop_agent(id)
    Process.sleep(50)
    RecordingBackend.reset()

    {:ok, _} =
      Loopyard.TestHelpers.start_agent(
        id: id,
        name: "Sub-agent Test",
        started_by: "test",
        backend: RecordingBackend,
        resume: true
      )

    opts = :sys.get_state(agent_pid(id)).init_opts
    assert Keyword.get(opts, :harness) == :claude
    assert Keyword.get(opts, :model) == "sonnet"
  end

  test "the same value is a no-op; an unknown model is refused", %{id: id} do
    pid = agent_pid(id)
    RecordingBackend.reset()

    ChatAgent.set_subagent_model(id, nil)
    ChatAgent.set_subagent_model(id, "gpt-nope")
    state = :sys.get_state(pid)

    assert RecordingBackend.starts() == []
    assert Keyword.get(state.session_opts, :subagent_model) == nil
  end

  test "a busy agent stores it at once but relaunches only after the turn", %{id: id} do
    pid = agent_pid(id)
    :sys.replace_state(pid, &%{&1 | status: :thinking})
    RecordingBackend.reset()

    ChatAgent.set_subagent_model(id, "sonnet")
    state = :sys.get_state(pid)
    assert Keyword.get(state.session_opts, :subagent_model) == "sonnet"
    assert RecordingBackend.starts() == [], "never kill a busy harness for a setting"
    flush_status(id)

    :sys.replace_state(pid, &%{&1 | status: :idle})
    assert_receive %Loopyard.Events.ChatAgent.StatusChanged{id: ^id, status: :backoff}, 3_500
    assert_receive %Loopyard.Events.ChatAgent.StatusChanged{id: ^id, status: :idle}, 1_000
    assert [opts] = RecordingBackend.starts()
    assert Keyword.get(opts, :subagent_model) == "sonnet"
  end

  test "a harness without the knob refuses it" do
    state = %{id: "x", name: "x", session_opts: [harness: :codex], status: :idle}
    assert {^state, {:error, :unsupported}} = SubagentControl.switch(state, "sonnet")
  end

  test "a harness switch drops it — a Claude id means nothing to Codex", %{id: id} do
    set_and_settle(id, "sonnet")
    ChatAgent.set_harness(id, :codex)
    assert_receive %Loopyard.Events.ChatAgent.StatusChanged{id: ^id, status: :idle}, 1_000
    state = :sys.get_state(agent_pid(id))
    refute Keyword.has_key?(state.session_opts, :subagent_model)
  end
end
