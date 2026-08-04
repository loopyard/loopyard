defmodule Loopyard.Harness.ACP.ToolInputFragmentsTest do
  @moduledoc """
  ACP delivers a tool call's `rawInput` in FRAGMENTS, and the whole call has to
  survive them.

  The translator used to REPLACE the buffered input with whichever fragment
  arrived last, and emitted the call from the FIRST fragment it saw. Measured on
  a live agent mid-refactor: five consecutive `Edit` calls, every one recorded
  as `%{"replace_all" => false}` — no file, no strings, nothing that says which
  edit it was.

  Two visible failures came out of that:

    * tool cards rendered an Edit with no file and no diff;
    * the same-tool-same-input loop guard hashed those identical husks and
      announced a retry loop over five edits to five DIFFERENT files —
      "Agent called `Edit` 5 times in a row with the same input".

  The second one is why this matters beyond cosmetics: a guard that reads
  corrupted evidence doesn't just miss loops, it invents them.
  """
  use ExUnit.Case, async: true

  alias Loopyard.Agent.Event
  alias Loopyard.Harness.ACP.Translator

  defp update(kind, id, fields),
    do: Map.merge(%{"sessionUpdate" => kind, "toolCallId" => id}, fields)

  defp drain(state, steps) do
    Enum.reduce(steps, {state, []}, fn payload, {st, acc} ->
      {st, evs} = Translator.step(st, payload)
      {st, acc ++ evs}
    end)
  end

  test "fragments accumulate instead of clobbering each other" do
    {_state, events} =
      drain(Translator.new(model: "m"), [
        update("tool_call", "t1", %{"title" => "Edit", "rawInput" => %{"replace_all" => false}}),
        update("tool_call_update", "t1", %{"rawInput" => %{"file_path" => "/workspace/a.css"}}),
        update("tool_call_update", "t1", %{"rawInput" => %{"old_string" => "terracotta"}})
      ])

    calls = Enum.filter(events, &match?(%Event.ToolCall{}, &1))
    assert calls != [], "the call has to reach the stream"

    final = List.last(calls)

    assert final.input["file_path"] == "/workspace/a.css",
           "a later fragment must REFINE the call, not replace it — got #{inspect(final.input)}"

    assert final.input["old_string"] == "terracotta"
    assert final.input["replace_all"] == false, "and the earliest fragment survives too"
  end

  test "two edits to different files do not look identical" do
    steps = fn id, path ->
      [
        update("tool_call", id, %{"title" => "Edit", "rawInput" => %{"replace_all" => false}}),
        update("tool_call_update", id, %{"rawInput" => %{"file_path" => path}})
      ]
    end

    {_state, events} =
      drain(Translator.new(model: "m"), steps.("t1", "/a.css") ++ steps.("t2", "/b.css"))

    inputs =
      events
      |> Enum.filter(&match?(%Event.ToolCall{}, &1))
      |> Enum.group_by(& &1.id)
      |> Enum.map(fn {_id, calls} -> List.last(calls).input end)

    assert length(Enum.uniq(inputs)) == 2,
           "edits to different files must be distinguishable — identical husks are " <>
             "what made the loop guard cry wolf. Got: #{inspect(inputs)}"
  end

  test "a refined call keeps its identity (same tool id, not a second call)" do
    {_state, events} =
      drain(Translator.new(model: "m"), [
        update("tool_call", "t1", %{"title" => "Edit", "rawInput" => %{"replace_all" => false}}),
        update("tool_call_update", "t1", %{"rawInput" => %{"file_path" => "/a.css"}})
      ])

    ids =
      events |> Enum.filter(&match?(%Event.ToolCall{}, &1)) |> Enum.map(& &1.id) |> Enum.uniq()

    assert ids == ["t1"],
           "refinement must reuse the tool id so the handler updates the message " <>
             "in place instead of recording a second call"
  end
end
