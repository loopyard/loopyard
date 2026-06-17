defmodule Loopyard.Harness.QuestionsTest do
  use ExUnit.Case, async: false

  alias Loopyard.Harness.Questions
  alias Loopyard.Harness.QuestionAdapter.ClaudeCode

  setup do
    Loopyard.StateKeeper.ensure_tables!()
    :ok
  end

  describe "ClaudeCode adapter" do
    test "normalizes Claude AskUserQuestion shape (incl. string options + missing keys)" do
      raw = [
        %{
          "question" => "Which framework?",
          "header" => "Framework",
          "multiSelect" => false,
          "options" => [%{"label" => "Rails", "description" => "Ruby"}, "Phoenix"]
        }
      ]

      assert {:ok, [q]} = ClaudeCode.parse(raw)
      assert q.id == "q0"
      assert q.prompt == "Which framework?"
      assert q.header == "Framework"
      refute q.multi

      assert [%{label: "Rails", description: "Ruby"}, %{label: "Phoenix", description: nil}] =
               q.options
    end

    test "accepts the {questions: [...]} envelope and rejects junk" do
      assert {:ok, [_]} =
               ClaudeCode.parse(%{"questions" => [%{"question" => "x", "options" => []}]})

      assert :error = ClaudeCode.parse([])
      assert :error = ClaudeCode.parse("nope")
    end

    test "render_answer maps selections back to text" do
      {:ok, [q]} = ClaudeCode.parse([%{"question" => "Pick?", "options" => [%{"label" => "A"}]}])
      assert ClaudeCode.render_answer([q], %{q.id => ["A"]}) =~ "Pick? → A"
      assert ClaudeCode.render_answer([q], %{}) =~ "(no answer)"
    end
  end

  describe "broker ask/answer" do
    test "ask blocks until answered, then returns the selections" do
      {:ok, questions} =
        ClaudeCode.parse([
          %{"question" => "Go?", "options" => [%{"label" => "Yes"}, %{"label" => "No"}]}
        ])

      task = Task.async(fn -> Questions.ask("q-test-agent", questions) end)

      # Wait for the pending question to register.
      qid = wait_for_pending()
      assert Questions.pending?(qid)

      assert :ok = Questions.answer(qid, %{"q0" => ["Yes"]})
      assert {:ok, %{"q0" => ["Yes"]}} = Task.await(task, 2_000)
      refute Questions.pending?(qid)
    end

    test "answering an unknown question is a clean error" do
      assert {:error, :not_found} =
               Questions.answer("nope-#{System.unique_integer()}", %{"q0" => ["x"]})
    end
  end

  describe "free-text answer (user typed instead of clicking)" do
    test "answer_with_text/2 resolves a pending question, flips it to :answered" do
      agent = "q-text-agent-#{System.unique_integer([:positive])}"

      {:ok, questions} =
        ClaudeCode.parse([
          %{"question" => "Go?", "options" => [%{"label" => "Yes"}, %{"label" => "No"}]}
        ])

      task = Task.async(fn -> Questions.ask(agent, questions) end)

      qid = wait_for_pending()
      assert Questions.pending_for_agent?(agent)

      assert :ok = Questions.answer_with_text(agent, "maybe later")

      # The blocked waiter unblocks with the typed text mapped onto each question.
      assert {:ok, %{"q0" => ["maybe later"]}} = Task.await(task, 2_000)
      refute Questions.pending?(qid)
    end

    test "answer_with_text/2 with nothing pending is a clean no-op" do
      assert {:error, :none_pending} =
               Questions.answer_with_text("q-none-#{System.unique_integer()}", "hi")
    end
  end

  describe "dead-waiter reaping" do
    test "pending_for_agent? reaps an entry whose waiter died" do
      agent = "q-dead-agent-#{System.unique_integer([:positive])}"

      {:ok, questions} =
        ClaudeCode.parse([%{"question" => "Go?", "options" => [%{"label" => "Yes"}]}])

      # Spawn a waiter that registers the question then exits, leaking the entry.
      {pid, ref} = spawn_monitor(fn -> Questions.ask(agent, questions) end)
      qid = wait_for_pending()
      assert Questions.pending?(qid)

      # Kill the waiter — the receive in ask/2 never delivers, entry leaks.
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000

      # First liveness check reaps the orphan.
      refute Questions.pending_for_agent?(agent)
      refute Questions.pending?(qid)
    end
  end

  defp wait_for_pending(tries \\ 50) do
    case :ets.tab2list(:harness_questions) do
      [{qid, _} | _] ->
        qid

      [] when tries > 0 ->
        Process.sleep(10)
        wait_for_pending(tries - 1)
    end
  end
end
