defmodule Loopyard.Harness.QuestionAdapter do
  @moduledoc """
  Per-harness translation of the "ask the user a question" round-trip.

  Different harnesses surface structured questions in different shapes — Claude
  Code's `AskUserQuestion`, Codex's (TBD), a custom harness's MCP tool. Each gets
  an adapter implementing this behaviour so the rest of Loopyard — the broker
  (`Loopyard.Harness.Questions`) and the UI card — works against ONE normalized
  shape and never learns a harness's quirks.

  The flow is the same for every harness: the harness calls into the broker with
  its raw question payload + the adapter; the broker normalizes, shows the UI,
  blocks until a human answers, then the adapter renders the answer back into
  whatever text/format the harness expects as the tool/round-trip result.

  ## Normalized shapes

      question :: %{
        id: String.t(),              # stable within this ask, e.g. "q0"
        header: String.t(),          # short chip label, e.g. "Auth method"
        prompt: String.t(),          # the actual question text
        multi: boolean(),            # multi-select?
        options: [%{id: String.t(), label: String.t(), description: String.t() | nil}]
      }

      selections :: %{question_id => [option_label]}   # what the human chose
  """

  @type question :: %{
          id: String.t(),
          header: String.t(),
          prompt: String.t(),
          multi: boolean(),
          options: [%{id: String.t(), label: String.t(), description: String.t() | nil}]
        }

  @type selections :: %{optional(String.t()) => [String.t()]}

  @doc "Normalize a harness's raw question payload into the common shape."
  @callback parse(raw :: term()) :: {:ok, [question()]} | :error

  @doc "Render the human's selections back into the harness's answer format."
  @callback render_answer(questions :: [question()], selections :: selections()) :: String.t()
end
