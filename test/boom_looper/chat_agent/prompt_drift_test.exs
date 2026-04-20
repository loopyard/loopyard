defmodule BoomLooper.ChatAgent.PromptDriftTest do
  @moduledoc """
  Surface #19 of plans/agent-sanity.md.

  `build_system_prompt` is rebuilt from scratch on every `start_session`,
  pulling the latest CLAUDE.md + tool set. When `init_resume` brings
  an agent back after a BoomLooper restart, its Claude session resumes
  via the CLI's `resume: <sid>` path — the CLI already baked in the OLD
  system prompt from the previous session, and we append the NEW one
  on top. After a significant refactor (tool renamed, rule added), the
  agent now sees two conflicting sets of instructions. That's hard to
  debug from the outside — the user just sees "the agent behaves
  weirdly after a restart."

  The fix: hash the full system prompt, persist alongside
  claude_session_id. On init_resume, compare. On mismatch, surface an
  inline `⚠ System prompt changed…` marker + emit telemetry. Silent
  drift is the failure mode this prevents.
  """

  use ExUnit.Case, async: false

  alias BoomLooper.ChatAgent
  alias BoomLooper.TestSupport.RecordingBackend

  @moduletag timeout: 10_000

  setup do
    RecordingBackend.reset()
    id = "prompt-drift-test-#{:rand.uniform(100_000)}"

    {:ok, _pid} =
      BoomLooper.TestHelpers.start_agent(
        id: id,
        name: "Prompt Drift Test",
        working_dir: File.cwd!(),
        started_by: "test",
        backend: RecordingBackend
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

    %{id: id}
  end

  defp agent_pid(id) do
    case Registry.lookup(BoomLooper.ChatAgentRegistry, id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  describe "surface #19: prompt drift detection" do
    test "prompt_hash is populated at init_fresh time", %{id: id} do
      state = :sys.get_state(agent_pid(id))
      assert is_binary(state.prompt_hash)
      assert String.length(state.prompt_hash) == 64  # hex-encoded SHA-256
    end

    test "prompt_hash flows to summary + ETS", %{id: id} do
      _state = :sys.get_state(agent_pid(id))
      [{^id, summary}] = :ets.lookup(:chat_agents, id)
      assert is_binary(summary.prompt_hash)
    end

    test "init_resume with matching hash → no drift marker appended", %{id: id} do
      pid = agent_pid(id)
      original_hash = :sys.get_state(pid).prompt_hash
      original_msg_count = length(:sys.get_state(pid).messages)

      ChatAgent.stop_agent(id)
      Process.sleep(30)

      {:ok, _} =
        BoomLooper.TestHelpers.start_agent(
          id: id,
          name: "Prompt Drift Test",
          working_dir: File.cwd!(),
          started_by: "test",
          backend: RecordingBackend,
          resume: true
        )

      new_state = :sys.get_state(agent_pid(id))

      # Same prompt inputs → same hash → no drift message appended.
      assert new_state.prompt_hash == original_hash

      drift_count =
        Enum.count(new_state.messages, fn m ->
          m.role == :system and String.contains?(m.content || "", "prompt changed")
        end)

      assert drift_count == 0
      assert length(new_state.messages) == original_msg_count
    end

    test "init_resume with DIFFERENT saved hash → inline drift marker appended", %{id: id} do
      pid = agent_pid(id)

      # Tamper via :sys.replace_state so the fake hash survives the
      # stop path: terminate/2 writes `summary(state)` back to ETS if
      # status isn't already :stopped, which would otherwise clobber a
      # direct `:ets.insert/2` of a tampered row with the real state.
      fake_hash = "0000000000000000000000000000000000000000000000000000000000000000"
      :sys.replace_state(pid, fn s -> %{s | prompt_hash: fake_hash} end)

      # Attach telemetry handler FIRST so we catch the emit during init_resume.
      parent = self()
      handler_id = "prompt-drift-test-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:boom_looper, :agent, :prompt_drift],
        fn _event, _measurements, meta, _config ->
          send(parent, {:prompt_drift, meta})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      ChatAgent.stop_agent(id)
      Process.sleep(50)

      {:ok, _} =
        BoomLooper.TestHelpers.start_agent(
          id: id,
          name: "Prompt Drift Test",
          working_dir: File.cwd!(),
          started_by: "test",
          backend: RecordingBackend,
          resume: true
        )

      assert_receive {:prompt_drift, meta}, 1_000
      assert meta.agent_id == id
      assert meta.old_hash == fake_hash
      assert meta.new_hash != meta.old_hash

      new_state = :sys.get_state(agent_pid(id))

      drift_msg =
        Enum.find(new_state.messages, fn m ->
          m.role == :system and String.contains?(m.content || "", "System prompt changed")
        end)

      assert drift_msg != nil,
             "init_resume must append an inline drift marker when prompt_hash differs"

      assert String.contains?(drift_msg.content, "behavior may differ")
    end

    test "init_resume with no saved hash (pre-fix agent) → no drift marker, no crash", %{id: id} do
      pid = agent_pid(id)

      [{^id, summary}] = :ets.lookup(:chat_agents, id)
      tampered = %{summary | prompt_hash: nil}
      :ets.insert(:chat_agents, {id, tampered})

      ChatAgent.stop_agent(id)
      Process.sleep(30)

      {:ok, _} =
        BoomLooper.TestHelpers.start_agent(
          id: id,
          name: "Prompt Drift Test",
          working_dir: File.cwd!(),
          started_by: "test",
          backend: RecordingBackend,
          resume: true
        )

      new_state = :sys.get_state(agent_pid(id))

      drift_count =
        Enum.count(new_state.messages, fn m ->
          m.role == :system and String.contains?(m.content || "", "prompt changed")
        end)

      assert drift_count == 0
      # New hash populated.
      assert is_binary(new_state.prompt_hash)
    end
  end
end
