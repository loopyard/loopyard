defmodule Loopyard.Tools.Container.AskUser do
  use Loopyard.Tool,
    name: "ask_user",
    description:
      "Ask the human question(s) and WAIT for the answers. Shows clickable " <>
        "option buttons in the chat — use this whenever you'd otherwise ask a " <>
        "question in prose and pause, e.g. choosing between approaches, confirming " <>
        "a decision, or picking a name. Blocks until every question is answered or " <>
        "skipped. Prefer 1-3 focused questions with 2-4 options each; announce them " <>
        "in prose first so they land with context. The user can skip any question " <>
        "(you'll see \"(skipped)\" — use your best judgment, don't re-ask) or type " <>
        "their own answer instead of picking an option. Each item in `questions`: " <>
        "{question: text, header: short 1-3 word label, multiSelect: false, " <>
        "options: [{label: short choice, description: what it means}]}.",
    busy_words: ["waiting on you", "asking"],
    params: [
      agent_id: {:string, required: true},
      questions: {:list, required: true, description: "List of question objects (usually one)."}
    ]

  alias Loopyard.Harness.Questions
  alias Loopyard.Harness.QuestionAdapter.ClaudeCode

  def execute(%{agent_id: agent_id, questions: raw}, _assigns) do
    case ClaudeCode.parse(raw) do
      {:ok, questions} ->
        case Questions.ask(agent_id, questions) do
          {:ok, selections} ->
            {:ok, ClaudeCode.render_answer(questions, selections)}

          {:error, :timeout} ->
            {:ok,
             "The user did not answer in time. Proceed with your best judgment, or ask again if it's essential."}
        end

      :error ->
        {:error,
         "Invalid `questions`. Pass a list like " <>
           "[{question: \"...\", header: \"...\", options: [{label: \"...\", description: \"...\"}]}]."}
    end
  end
end
