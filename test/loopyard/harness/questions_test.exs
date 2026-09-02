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
      assert ClaudeCode.render_answer([q], %{}) =~ "(skipped"
    end
  end

  describe "AcpElicitation adapter (native AskUserQuestion over ACP form elicitation)" do
    alias Loopyard.Harness.QuestionAdapter.AcpElicitation

    # The claude-agent-acp shape: question_<n> selection fields (+ per-question
    # question_<n>_custom "Other" boxes), single question's text in `message`.
    defp elicitation_params do
      %{
        "mode" => "form",
        "message" => "Please answer the following questions.",
        "requestedSchema" => %{
          "type" => "object",
          "properties" => %{
            "question_0" => %{
              "type" => "string",
              "title" => "Persistence",
              "description" => "What happens to VIP status?",
              "oneOf" => [
                %{"const" => "Graduate", "title" => "Graduate", "description" => "Auto-clears"},
                %{"const" => "VIP forever", "title" => "VIP forever"}
              ]
            },
            "question_0_custom" => %{"type" => "string", "title" => "Other"},
            "question_1" => %{
              "type" => "array",
              "title" => "Channels",
              "description" => "Which channels?",
              "items" => %{
                "anyOf" => [%{"const" => "Email"}, %{"const" => "SMS"}]
              }
            },
            "question_1_custom" => %{"type" => "string", "title" => "Other"}
          }
        }
      }
    end

    test "parses the question_<n> schema into normalized questions (custom fields excluded)" do
      assert {:ok, [q0, q1]} = AcpElicitation.parse(elicitation_params())

      assert q0.id == "question_0"
      assert q0.header == "Persistence"
      assert q0.prompt == "What happens to VIP status?"
      refute q0.multi

      assert [%{label: "Graduate", description: "Auto-clears"}, %{label: "VIP forever"}] =
               q0.options

      assert q1.id == "question_1"
      assert q1.multi
      assert [%{label: "Email"}, %{label: "SMS"}] = q1.options
    end

    test "single question takes its prompt from the top-level message" do
      params = %{
        "message" => "Deploy now?",
        "requestedSchema" => %{
          "properties" => %{
            "question_0" => %{"type" => "string", "oneOf" => [%{"const" => "Yes"}]},
            "question_0_custom" => %{"type" => "string"}
          }
        }
      }

      assert {:ok, [q]} = AcpElicitation.parse(params)
      assert q.prompt == "Deploy now?"
    end

    test "render_content: option labels to fields, free text to _custom, skips omitted" do
      {:ok, [q0, q1]} = AcpElicitation.parse(elicitation_params())

      # single-select option, multi-select list
      assert AcpElicitation.render_content([q0, q1], %{
               "question_0" => ["VIP forever"],
               "question_1" => ["Email", "SMS"]
             }) == %{"question_0" => "VIP forever", "question_1" => ["Email", "SMS"]}

      # free text (not an option label) goes to the custom field; skip omitted
      assert AcpElicitation.render_content([q0, q1], %{
               "question_0" => ["keep them special but let them unsubscribe"],
               "question_1" => []
             }) == %{"question_0_custom" => "keep them special but let them unsubscribe"}
    end

    test "rejects schemas with no question fields" do
      assert :error = AcpElicitation.parse(%{"requestedSchema" => %{"properties" => %{}}})
      assert :error = AcpElicitation.parse(%{"mode" => "url"})
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

  describe "per-question progressive answering" do
    # THE bug this guards: a 3-question ask used to resolve on the FIRST click,
    # returning "(no answer)" for the other two and showing them as answered.
    test "a multi-question ask resolves only when every question is settled" do
      {:ok, questions} =
        ClaudeCode.parse([
          %{"question" => "One?", "options" => [%{"label" => "A"}, %{"label" => "B"}]},
          %{"question" => "Two?", "options" => [%{"label" => "C"}]},
          %{"question" => "Three?", "options" => [%{"label" => "D"}]}
        ])

      task = Task.async(fn -> Questions.ask("q-multi-agent", questions) end)
      qid = wait_for_pending()

      # First answer does NOT resolve the ask.
      assert :ok = Questions.answer_partial(qid, "q0", ["A"])
      assert Questions.pending?(qid)
      assert nil == Task.yield(task, 50)

      # Second question skipped — still pending on the third.
      assert :ok = Questions.answer_partial(qid, "q1", [])
      assert Questions.pending?(qid)

      # Last one settles the whole ask with everything accumulated.
      assert :ok = Questions.answer_partial(qid, "q2", ["D"])

      assert {:ok, %{"q0" => ["A"], "q1" => [], "q2" => ["D"]}} = Task.await(task, 2_000)
      refute Questions.pending?(qid)
    end

    test "multi-select: toggles accumulate without resolving; confirm settles" do
      {:ok, questions} =
        ClaudeCode.parse([
          %{
            "question" => "Which?",
            "multiSelect" => true,
            "options" => [%{"label" => "X"}, %{"label" => "Y"}, %{"label" => "Z"}]
          }
        ])

      task = Task.async(fn -> Questions.ask("q-toggle-agent", questions) end)
      qid = wait_for_pending()

      assert :ok = Questions.toggle_option(qid, "q0", "X")
      assert :ok = Questions.toggle_option(qid, "q0", "Y")
      # toggling off works
      assert :ok = Questions.toggle_option(qid, "q0", "X")
      assert Questions.pending?(qid)

      assert :ok = Questions.confirm_question(qid, "q0")
      assert {:ok, %{"q0" => ["Y"]}} = Task.await(task, 2_000)
    end

    test "typed chat text answers only the still-open questions" do
      agent = "q-mixed-agent-#{System.unique_integer([:positive])}"

      {:ok, questions} =
        ClaudeCode.parse([
          %{"question" => "One?", "options" => [%{"label" => "A"}]},
          %{"question" => "Two?", "options" => [%{"label" => "B"}]}
        ])

      task = Task.async(fn -> Questions.ask(agent, questions) end)
      qid = wait_for_pending()

      assert :ok = Questions.answer_partial(qid, "q0", ["A"])
      assert :ok = Questions.answer_with_text(agent, "actually just ship it")

      assert {:ok, %{"q0" => ["A"], "q1" => ["actually just ship it"]}} = Task.await(task, 2_000)
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

    test "answer_with_text/2 answers the NEWEST live ask when several are pending" do
      # Seen live: the harness abandons an elicitation on its own clock while
      # our ask keeps blocking, so leaked-but-alive waiters pile up. A typed
      # reply must go to the ask the agent is actually parked on — the newest
      # — never to a stale one that happens to come first in ETS.
      agent = "q-newest-agent-#{System.unique_integer([:positive])}"

      {:ok, older_q} =
        ClaudeCode.parse([%{"question" => "Old?", "options" => [%{"label" => "A"}]}])

      {:ok, newer_q} =
        ClaudeCode.parse([%{"question" => "New?", "options" => [%{"label" => "B"}]}])

      older = Task.async(fn -> Questions.ask(agent, older_q) end)
      older_qid = wait_for_pending()
      Process.sleep(5)
      newer = Task.async(fn -> Questions.ask(agent, newer_q) end)

      newer_qid =
        Enum.find_value(1..100, fn _ ->
          :ets.tab2list(:harness_questions)
          |> Enum.find_value(fn
            {qid, %{agent_id: ^agent}} when qid != older_qid -> qid
            _ -> nil
          end) || (Process.sleep(10) && nil)
        end)

      assert is_binary(newer_qid)

      assert :ok = Questions.answer_with_text(agent, "the new one")

      assert {:ok, %{"q0" => ["the new one"]}} = Task.await(newer, 2_000)
      assert Questions.pending?(older_qid), "the stale ask must not have taken the reply"
      Task.shutdown(older, :brutal_kill)
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
