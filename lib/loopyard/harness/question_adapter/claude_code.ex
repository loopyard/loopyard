defmodule Loopyard.Harness.QuestionAdapter.ClaudeCode do
  @moduledoc """
  Question adapter for the Claude Code harness (custom backend today, via the
  `ask_user` MCP tool). Mirrors Claude's `AskUserQuestion` shape:

      [%{"question" => "...", "header" => "...", "multiSelect" => false,
         "options" => [%{"label" => "...", "description" => "..."}]}]

  Tolerant of string options and missing keys so a slightly-off agent payload
  still renders something usable.
  """
  @behaviour Loopyard.Harness.QuestionAdapter

  @impl true
  def parse(%{"questions" => qs}), do: parse(qs)

  def parse(qs) when is_list(qs) and qs != [] do
    {:ok, qs |> Enum.with_index() |> Enum.map(fn {q, i} -> normalize_question(q, i) end)}
  end

  def parse(_), do: :error

  @impl true
  def render_answer(questions, selections) do
    questions
    |> Enum.map(fn q ->
      chosen = Map.get(selections, q.id, [])
      "#{q.prompt} → #{if chosen == [], do: "(no answer)", else: Enum.join(chosen, ", ")}"
    end)
    |> Enum.join("\n")
  end

  # --- internals ---

  defp normalize_question(q, i) when is_map(q) do
    %{
      id: "q#{i}",
      header: get(q, ["header"]) || "",
      prompt: get(q, ["question", "prompt", "text"]) || "",
      multi: !!get(q, ["multiSelect", "multi"]),
      options:
        (get(q, ["options"]) || [])
        |> Enum.with_index()
        |> Enum.map(fn {o, oi} -> normalize_option(o, oi) end)
    }
  end

  defp normalize_question(other, i),
    do: %{id: "q#{i}", header: "", prompt: to_string(other), multi: false, options: []}

  defp normalize_option(o, oi) when is_binary(o), do: %{id: "o#{oi}", label: o, description: nil}

  defp normalize_option(o, oi) when is_map(o),
    do: %{
      id: "o#{oi}",
      label: get(o, ["label", "value"]) || "",
      description: get(o, ["description"])
    }

  defp normalize_option(o, oi), do: %{id: "o#{oi}", label: to_string(o), description: nil}

  # First non-nil value across candidate keys (string-keyed maps).
  defp get(m, keys) when is_map(m), do: Enum.find_value(keys, fn k -> Map.get(m, k) end)
end
