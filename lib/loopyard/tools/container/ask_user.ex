defmodule Loopyard.Tools.Container.AskUser do
  use Loopyard.Tool,
    name: "ask_user",
    description:
      "Post a MEMO to the human and WAIT for their response. A memo is ONE " <>
        "self-contained card on the chat timeline: it carries its own context, so " <>
        "the `question` text IS the memo (say what happened + the ask in 1-3 " <>
        "sentences) — do NOT restate it in prose around the card. Shows clickable " <>
        "option buttons; the user can pick one, skip (\"(skipped)\" — use your best " <>
        "judgment, don't re-ask), or type their own reply. Blocks until every " <>
        "question is answered or skipped. Prefer 1-3 focused questions with 2-4 " <>
        "options each. Each item in `questions`: {question: text (the memo body), " <>
        "header: short 1-3 word label, multiSelect: false, options: [{label: short " <>
        "choice, description: what it means}]}. Set `source` to the project/" <>
        "workspace this memo is about so the human knows where it's from. NAME " <>
        "THE THING: never 'this repo', 'that app', 'it', 'the change' — the human " <>
        "may read the card days later, alone, with none of this chat around it. " <>
        "Write the repo's name, the path, the branch, the amount. If the question " <>
        "wouldn't make sense to someone who never saw this conversation, rewrite it.",
    # Busy words fill the WORKING slot (elapsed timer + Stop button), so they
    # must describe what the agent is DOING, not the state it's about to enter.
    # "waiting on you" read as blocked-on-a-human while the working chrome said
    # otherwise — a contradiction. That meaning belongs to the pending-question
    # card/composer band, never the busy rotation. Keep it to the busy act.
    busy_words: ["asking", "drafting a question"],
    params: [
      agent_id: {:string, required: true},
      questions: {:list, required: true, description: "List of question objects (usually one)."},
      source:
        {:string,
         required: false,
         description:
           "The REAL project — and optionally its real workspace/branch — this memo is about, e.g. 'firehose-site · main' or just 'Loopyard'. This is an IDENTITY, not a topic: what's after the · MUST be an actual workspace name (never a subject like 'system health' — that goes in the question header). Omit if not tied to a project."}
    ]

  alias Loopyard.Harness.Questions
  alias Loopyard.Harness.QuestionAdapter.ClaudeCode

  def execute(%{agent_id: agent_id, questions: raw} = args, _assigns) do
    case ClaudeCode.parse(raw) do
      {:ok, questions} ->
        case Questions.ask(agent_id, questions, args[:source]) do
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
