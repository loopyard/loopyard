defmodule Loopyard.Agent.Backend.ACP.TranslatorTest do
  use ExUnit.Case, async: true

  alias Loopyard.Agent.Backend.ACP.Translator
  alias Loopyard.Agent.Event

  @fixture "test/support/fixtures/acp/smoke_transcript.jsonl"

  # Replay the real captured ACP transcript through the reducer and return
  # the flat list of translated events (including the end-of-turn flush).
  defp replay(stop_reason \\ "end_turn") do
    updates =
      @fixture
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.starts_with?(&1, "<< "))
      |> Enum.map(&(&1 |> String.replace_prefix("<< ", "") |> Jason.decode!()))
      |> Enum.filter(&(&1["method"] == "session/update"))
      |> Enum.map(&get_in(&1, ["params", "update"]))

    {state, events} =
      Enum.reduce(updates, {Translator.new(model: "test-model"), []}, fn update, {st, acc} ->
        {st, evs} = Translator.step(st, update)
        {st, acc ++ evs}
      end)

    {_state, tail} = Translator.finish(state, stop_reason)
    events ++ tail
  end

  test "fixture has real session/update frames" do
    # Sanity: the captured transcript actually contains streamed updates.
    body = File.read!(@fixture)
    assert body =~ "agent_message_chunk"
    assert body =~ "tool_call"
  end

  test "streams text deltas and emits one final committed Text" do
    events = replay()

    assert Enum.any?(events, &match?(%Event.TextDelta{}, &1)),
           "expected live TextDelta events"

    texts = Enum.filter(events, &match?(%Event.Text{}, &1))

    assert [%Event.Text{text: full}] = texts,
           "expected exactly one final Text, got #{length(texts)}"

    # Full message is the concatenation of all chunks.
    assert full =~ "Hello"
    assert full =~ "app name is `:loopyard`"
  end

  test "emits exactly one ToolCall and one ToolResult per tool, deduped across frames" do
    events = replay()

    calls = Enum.filter(events, &match?(%Event.ToolCall{}, &1))
    results = Enum.filter(events, &match?(%Event.ToolResult{}, &1))

    assert [%Event.ToolCall{id: id, name: name, input: input}] = calls
    assert id == "toolu_01MLbjUj3KHyrNfajLQrj4SN"
    assert name == "mcp__acp__Read"
    assert input["file_path"] =~ "mix.exs"

    assert [%Event.ToolResult{id: ^id, content: content, is_error: false}] = results
    assert content =~ "defmodule Loopyard.MixProject"
  end

  test "surfaces available slash-commands/skills as a SystemEvent" do
    events = replay()

    cmds =
      Enum.filter(events, &match?(%Event.SystemEvent{subtype: :available_commands}, &1))

    assert [%Event.SystemEvent{content: content}] = cmds
    assert is_binary(content) and content != ""
  end

  test "finishes with a SessionResult carrying the model" do
    events = replay()
    assert %Event.SessionResult{model: "test-model"} = List.last(events)
  end

  test "ordering: tool call precedes its result, result precedes final Text" do
    events = replay()
    types = Enum.map(events, & &1.__struct__)

    call_idx = Enum.find_index(types, &(&1 == Event.ToolCall))
    result_idx = Enum.find_index(types, &(&1 == Event.ToolResult))
    text_idx = Enum.find_index(types, &(&1 == Event.Text))

    assert call_idx < result_idx
    assert result_idx < text_idx
  end
end
