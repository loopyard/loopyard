defmodule Loopyard.Harness.QuestionAdapter.AcpElicitation do
  @moduledoc """
  Question adapter for ACP **form elicitations** (`elicitation/create`,
  mode `"form"`) — how the in-container Claude Code harness surfaces its
  native `AskUserQuestion` tool when the client advertises the
  `elicitation.form` capability (claude-agent-acp ≥ 0.60).

  The adapter (`claude-agent-acp/dist/elicitation.js`) encodes each question
  as TWO schema properties:

    * `question_<n>` — the selection field. Single-select: `type: "string"`
      with a `oneOf` of `%{const: label, title: label, description: ...}`
      enum options. Multi-select: `type: "array"` with `items.anyOf` of the
      same option shape. `title` carries the question's short header,
      `description` the question text (omitted for a single question, whose
      text rides in the top-level `message` instead).
    * `question_<n>_custom` — the per-question free-text "Other" box.

  Nothing is required — every question is skippable, matching the built-in
  tool. We keep the wire field key as the normalized question `id`, so the
  card's selections map back onto response content without a translation
  table: chosen option labels go under `question_<n>` (string for single,
  array for multi), and a selection that is NOT one of the option labels
  (typed via "Other" or free text in chat) goes under `question_<n>_custom`,
  which the adapter gives precedence.
  """
  @behaviour Loopyard.Harness.QuestionAdapter

  @impl true
  def parse(%{"requestedSchema" => %{"properties" => props}} = params) when is_map(props) do
    field_keys =
      props
      |> Map.keys()
      |> Enum.filter(&Regex.match?(~r/^question_\d+$/, &1))
      |> Enum.sort_by(fn "question_" <> n -> String.to_integer(n) end)

    case field_keys do
      [] ->
        :error

      keys ->
        single? = length(keys) == 1
        message = params["message"]
        {:ok, Enum.map(keys, &normalize_question(&1, props[&1], single? && message))}
    end
  end

  def parse(_), do: :error

  @doc """
  Render the human's selections as the elicitation response `content` map.
  Skipped questions (empty selection) are simply omitted — the harness tells
  the model the user skipped them.
  """
  @impl true
  def render_answer(questions, selections) do
    questions
    |> render_content(selections)
    |> Jason.encode!()
  end

  @spec render_content([Loopyard.Harness.QuestionAdapter.question()], map()) :: map()
  def render_content(questions, selections) do
    Enum.reduce(questions, %{}, fn q, content ->
      labels = Map.get(selections, q.id, [])
      option_labels = MapSet.new(q.options, & &1.label)
      {known, custom} = Enum.split_with(labels, &MapSet.member?(option_labels, &1))

      content =
        case known do
          [] -> content
          _ when q.multi -> Map.put(content, q.id, known)
          [first | _] -> Map.put(content, q.id, first)
        end

      case custom do
        [] -> content
        text -> Map.put(content, "#{q.id}_custom", Enum.join(text, ", "))
      end
    end)
  end

  # --- internals ---

  defp normalize_question(key, prop, single_message) when is_map(prop) do
    multi = prop["type"] == "array"

    options =
      (prop["oneOf"] || get_in(prop, ["items", "anyOf"]) || [])
      |> Enum.with_index()
      |> Enum.map(fn {o, oi} ->
        %{
          id: "o#{oi}",
          label: to_string(o["const"] || o["title"] || ""),
          description: o["description"]
        }
      end)

    %{
      id: key,
      header: prop["title"] || "",
      prompt: prop["description"] || single_message || "",
      multi: multi,
      options: options
    }
  end

  defp normalize_question(key, _prop, single_message),
    do: %{id: key, header: "", prompt: single_message || "", multi: false, options: []}
end
