defmodule Loopyard.ChatAgent.TurnRetryTest do
  @moduledoc """
  A turn that fails on a transient upstream error (529 / overload /
  `error_during_execution`) must NEVER silently lose the user's text.

  Default behavior (`:agent_turn_retries` = 0): preserve the prompt, surface a
  clear error, and hand the text back to the box (`{:restore_input, ...}`) — the
  human hits Send to retry, manually, as many times as they like.

  Opt-in (`:agent_turn_retries` > 0): bounded auto-retry with backoff.
  """
  use ExUnit.Case, async: false

  alias Loopyard.ChatAgent
  alias Loopyard.Agent.Event
  alias Loopyard.ChatAgent.StreamHandler
  alias Loopyard.TestSupport.RecordingBackend

  @moduletag timeout: 10_000

  setup do
    RecordingBackend.reset()
    id = "retry-test-#{:rand.uniform(100_000)}"

    {:ok, _pid} =
      Loopyard.TestHelpers.start_agent(
        id: id,
        name: "Retry Test",
        working_dir: File.cwd!(),
        started_by: "test",
        backend: RecordingBackend
      )

    on_exit(fn ->
      Application.delete_env(:loopyard, :agent_turn_retries)

      try do
        ChatAgent.stop_agent(id)
      catch
        :exit, _ -> :ok
      end

      Process.sleep(20)
    end)

    %{id: id, pid: hd(Registry.lookup(Loopyard.ChatAgentRegistry, id)) |> elem(0)}
  end

  defp in_turn(pid, attempt \\ 0) do
    ref = make_ref()

    :sys.replace_state(pid, fn s ->
      %{
        s
        | status: :thinking,
          stream_ref: ref,
          current_turn_prompt: "make the thing",
          turn_retry_count: attempt
      }
    end)

    ref
  end

  defp fail_turn(pid, id, ref, subtype) do
    send(
      pid,
      {:stream_event, id, ref, %Event.SessionResult{is_error: true, error_subtype: subtype}}
    )

    Process.sleep(20)
    send(pid, {:stream_done, id, ref})
    Process.sleep(50)
  end

  describe "retryable classification" do
    test "execution errors / unknowns are transient; limit-class are not" do
      assert StreamHandler.retryable_turn_error?("error_during_execution")
      assert StreamHandler.retryable_turn_error?("overloaded_error")
      refute StreamHandler.retryable_turn_error?("error_max_turns")
      refute StreamHandler.retryable_turn_error?("error_max_budget_usd")
      refute StreamHandler.retryable_turn_error?(nil)
    end
  end

  describe "default (no auto-retry): preserve + hand back the text" do
    test "a transient failure goes idle, preserves the prompt, surfaces a retry error",
         %{id: id, pid: pid} do
      ref = in_turn(pid)
      fail_turn(pid, id, ref, "error_during_execution")

      state = :sys.get_state(pid)
      assert state.status == :idle
      assert state.turn_retry_count == 0
      assert state.failed_prompt == "make the thing"

      # Terse copy — the UI already shows the restored text; the error just needs
      # to say it failed and how to retry (no "we kept your text" narration).
      assert Enum.any?(state.messages, fn m ->
               m.role == :error and String.contains?(m.content, "tap Send to retry")
             end)
    end

    test "failed_prompt rides the ETS summary so the LiveView can refill the box",
         %{id: id, pid: pid} do
      ref = in_turn(pid)
      fail_turn(pid, id, ref, "error_during_execution")

      [{^id, summary}] = :ets.lookup(:chat_agents, id)
      assert summary.failed_prompt == "make the thing"
    end

    test "a non-retryable (max-turns) failure does NOT preserve/restore", %{id: id, pid: pid} do
      ref = in_turn(pid)
      fail_turn(pid, id, ref, "error_max_turns")

      state = :sys.get_state(pid)
      assert state.status == :idle
      assert state.failed_prompt == nil
    end

    test "a fresh send clears the preserved prompt", %{id: id, pid: pid} do
      :sys.replace_state(pid, fn s -> %{s | status: :idle, failed_prompt: "old text"} end)

      ChatAgent.send_message(id, "a brand new message")
      Process.sleep(80)

      assert :sys.get_state(pid).failed_prompt == nil
    end
  end

  describe "opt-in auto-retry (:agent_turn_retries > 0)" do
    test "retries with a counter + an honest note, staying thinking", %{id: id, pid: pid} do
      Application.put_env(:loopyard, :agent_turn_retries, 2)

      ref = in_turn(pid, 0)
      fail_turn(pid, id, ref, "error_during_execution")

      state = :sys.get_state(pid)
      assert state.turn_retry_count == 1
      assert state.status == :thinking

      assert Enum.any?(state.messages, fn m ->
               m.role == :system and String.contains?(m.content, "Retrying (1/2)")
             end)
    end

    test "once the budget is spent, it preserves the prompt instead", %{id: id, pid: pid} do
      Application.put_env(:loopyard, :agent_turn_retries, 2)

      ref = in_turn(pid, 2)
      fail_turn(pid, id, ref, "error_during_execution")

      state = :sys.get_state(pid)
      assert state.status == :idle
      assert state.failed_prompt == "make the thing"
    end
  end
end
