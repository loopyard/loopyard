defmodule Loopyard.Harness.ACP.TranslatorTest do
  @moduledoc """
  Pure unit tests for the ACP `session/update` → `%Event.*{}` reducer.

  No Docker, no Port, no subprocess — the translator is a pure function
  over decoded ACP frames, so these are fast and deterministic. The subtle
  surface is the tool-call dedup/buffering across multiple frames; those
  paths get the most coverage here.
  """
  use ExUnit.Case, async: true

  alias Loopyard.Harness.ACP.Translator
  alias Loopyard.Agent.Event

  # Run a list of update maps through step/2, collecting all emitted events
  # and returning {final_state, all_events}.
  defp run(state, updates) do
    Enum.reduce(updates, {state, []}, fn update, {st, acc} ->
      {st, events} = Translator.step(st, update)
      {st, acc ++ events}
    end)
  end

  defp chunk(text), do: %{"type" => "text", "text" => text}

  describe "text-block separation across tool calls (no jammed sentences)" do
    test "a tool call between two text blocks inserts a paragraph break" do
      {state, events} =
        run(Translator.new(), [
          %{"sessionUpdate" => "agent_message_chunk", "content" => chunk("Checking main.")},
          %{
            "sessionUpdate" => "tool_call",
            "toolCallId" => "t1",
            "title" => "Bash",
            "rawInput" => %{"command" => "gh pr view"}
          },
          %{"sessionUpdate" => "agent_message_chunk", "content" => chunk("No — not merged.")}
        ])

      # The break rides the LIVE delta too, so browser + committed text match.
      assert %Event.TextDelta{text: "\n\nNo — not merged."} =
               Enum.find(events, &match?(%Event.TextDelta{text: "\n\n" <> _}, &1))

      {_state, finish_events} = Translator.finish(state, nil)
      assert %Event.Text{text: "Checking main.\n\nNo — not merged."} = hd(finish_events)
    end

    test "deltas WITHIN one block (no tool between) are NOT broken apart" do
      {state, _} =
        run(Translator.new(), [
          %{"sessionUpdate" => "agent_message_chunk", "content" => chunk("Hello ")},
          %{"sessionUpdate" => "agent_message_chunk", "content" => chunk("world.")}
        ])

      {_state, finish_events} = Translator.finish(state, nil)
      assert %Event.Text{text: "Hello world."} = hd(finish_events)
    end

    test "no leading break when text opens the turn after a tool call" do
      {state, _} =
        run(Translator.new(), [
          %{
            "sessionUpdate" => "tool_call",
            "toolCallId" => "t1",
            "title" => "Bash",
            "rawInput" => %{"command" => "ls"}
          },
          %{"sessionUpdate" => "agent_message_chunk", "content" => chunk("Done.")}
        ])

      {_state, finish_events} = Translator.finish(state, nil)
      assert %Event.Text{text: "Done."} = hd(finish_events)
    end
  end

  describe "tool-result unwrapping (claude-code-acp display wrappers)" do
    defp result_update(id, content, status \\ "completed") do
      %{
        "sessionUpdate" => "tool_call_update",
        "toolCallId" => id,
        "status" => status,
        "content" => %{"type" => "text", "text" => content}
      }
    end

    defp result_content(events) do
      Enum.find_value(events, fn
        %Event.ToolResult{} = r -> r
        _ -> nil
      end)
    end

    test "strips the outer markdown code fence that wraps the whole result" do
      {_state, events} =
        run(Translator.new(), [
          %{"sessionUpdate" => "tool_call", "toolCallId" => "t1", "title" => "Bash",
            "rawInput" => %{"command" => "gh"}},
          result_update("t1", "```\nstate\nurl\n```")
        ])

      assert %Event.ToolResult{content: "state\nurl", is_error: false} = result_content(events)
    end

    test "unwraps <tool_use_error> AND flags is_error even on a non-failed status" do
      {_state, events} =
        run(Translator.new(), [
          %{"sessionUpdate" => "tool_call", "toolCallId" => "e1", "title" => "Read",
            "rawInput" => %{"path" => "/x"}},
          result_update("e1", "```\n<tool_use_error>Path does not exist: /x</tool_use_error>\n```")
        ])

      assert %Event.ToolResult{content: "Path does not exist: /x", is_error: true} =
               result_content(events)
    end

    test "a fence in the MIDDLE of output is preserved (only the outer wrapper is stripped)" do
      {_state, events} =
        run(Translator.new(), [
          %{"sessionUpdate" => "tool_call", "toolCallId" => "m1", "title" => "Bash",
            "rawInput" => %{"command" => "cat x"}},
          result_update("m1", "here is code:\n```js\nx()\n```\ndone")
        ])

      assert %Event.ToolResult{content: "here is code:\n```js\nx()\n```\ndone"} =
               result_content(events)
    end
  end

  describe "agent_message_chunk (text deltas)" do
    test "emits a TextDelta per non-empty chunk and accumulates for finish" do
      {state, events} =
        run(Translator.new(model: "claude-x"), [
          %{"sessionUpdate" => "agent_message_chunk", "content" => chunk("Hello, ")},
          %{"sessionUpdate" => "agent_message_chunk", "content" => chunk("world")}
        ])

      assert events == [
               %Event.TextDelta{text: "Hello, "},
               %Event.TextDelta{text: "world"}
             ]

      # finish flushes the accumulated full text as a single committed Text.
      {_state, finish_events} = Translator.finish(state, "end_turn")

      assert %Event.Text{text: "Hello, world"} = hd(finish_events)
    end

    test "drops empty text chunks (no delta, no accumulation)" do
      {state, events} =
        run(Translator.new(), [
          %{"sessionUpdate" => "agent_message_chunk", "content" => chunk("")},
          %{"sessionUpdate" => "agent_message_chunk", "content" => %{"type" => "image"}}
        ])

      assert events == []

      {_state, finish_events} = Translator.finish(state, nil)
      # No Text event when nothing accumulated — only the SessionResult.
      assert Enum.all?(finish_events, &match?(%Event.SessionResult{}, &1))
    end

    test "digs text out of nested / list content shapes" do
      {_state, events} =
        run(Translator.new(), [
          %{
            "sessionUpdate" => "agent_message_chunk",
            "content" => [chunk("a"), chunk("b"), %{"type" => "image"}]
          },
          %{
            "sessionUpdate" => "agent_message_chunk",
            "content" => %{"content" => %{"text" => "c"}}
          }
        ])

      assert events == [
               %Event.TextDelta{text: "ab"},
               %Event.TextDelta{text: "c"}
             ]
    end
  end

  describe "agent_thought_chunk (thinking deltas)" do
    test "emits ThinkingDelta but does NOT accumulate into the committed Text" do
      {state, events} =
        run(Translator.new(), [
          %{"sessionUpdate" => "agent_thought_chunk", "content" => chunk("hmm...")}
        ])

      assert events == [%Event.ThinkingDelta{thinking: "hmm..."}]

      {_state, finish_events} = Translator.finish(state, nil)
      # Thinking is display-only; the finalized message text stays empty.
      refute Enum.any?(finish_events, &match?(%Event.Text{}, &1))
    end

    test "drops empty thinking" do
      {_state, events} =
        run(Translator.new(), [
          %{"sessionUpdate" => "agent_thought_chunk", "content" => chunk("")}
        ])

      assert events == []
    end
  end

  describe "tool_call buffering / dedup" do
    test "buffers a title-only tool_call and emits nothing until input is known" do
      # First frame: title only, empty rawInput → buffered, no event.
      {state, events1} =
        Translator.step(Translator.new(), %{
          "sessionUpdate" => "tool_call",
          "toolCallId" => "t1",
          "title" => "Read",
          "rawInput" => %{}
        })

      assert events1 == []

      # Second frame: rawInput arrives → exactly one ToolCall emitted.
      {state, events2} =
        Translator.step(state, %{
          "sessionUpdate" => "tool_call",
          "toolCallId" => "t1",
          "rawInput" => %{"path" => "/a"}
        })

      assert events2 == [%Event.ToolCall{id: "t1", name: "Read", input: %{"path" => "/a"}}]

      # Third frame with same id: already emitted → no duplicate ToolCall.
      {_state, events3} =
        Translator.step(state, %{
          "sessionUpdate" => "tool_call",
          "toolCallId" => "t1",
          "rawInput" => %{"path" => "/a"}
        })

      assert events3 == []
    end

    test "emits ToolCall immediately when first frame already has input" do
      {_state, events} =
        Translator.step(Translator.new(), %{
          "sessionUpdate" => "tool_call",
          "toolCallId" => "t1",
          "title" => "Bash",
          "rawInput" => %{"command" => "ls"}
        })

      assert events == [%Event.ToolCall{id: "t1", name: "Bash", input: %{"command" => "ls"}}]
    end

    test "prefers Claude's internal tool name from _meta, falls back to title then kind" do
      meta = %{"_meta" => %{"claudeCode" => %{"toolName" => "Edit"}}}

      {_state, [call]} =
        Translator.step(
          Translator.new(),
          Map.merge(meta, %{
            "sessionUpdate" => "tool_call",
            "toolCallId" => "t1",
            "title" => "Editing file",
            "kind" => "edit",
            "rawInput" => %{"file" => "x"}
          })
        )

      assert call.name == "Edit"
    end

    test "a later frame's nil name does not clobber an earlier good name" do
      {state, _} =
        Translator.step(Translator.new(), %{
          "sessionUpdate" => "tool_call",
          "toolCallId" => "t1",
          "title" => "Read",
          "rawInput" => %{}
        })

      # Update with no name fields but with input → emit with the buffered name.
      {_state, [call]} =
        Translator.step(state, %{
          "sessionUpdate" => "tool_call",
          "toolCallId" => "t1",
          "rawInput" => %{"path" => "/a"}
        })

      assert call.name == "Read"
    end
  end

  describe "tool_call_update (forcing call out + result)" do
    test "forces the buffered ToolCall out, then emits one ToolResult" do
      # Buffer a title-only call (not yet emitted).
      {state, []} =
        Translator.step(Translator.new(), %{
          "sessionUpdate" => "tool_call",
          "toolCallId" => "t1",
          "title" => "Read",
          "rawInput" => %{}
        })

      # An update carrying the result forces the ToolCall out, then the result.
      {state, events} =
        Translator.step(state, %{
          "sessionUpdate" => "tool_call_update",
          "toolCallId" => "t1",
          "status" => "completed",
          "content" => chunk("file contents")
        })

      assert events == [
               %Event.ToolCall{id: "t1", name: "Read", input: %{}},
               %Event.ToolResult{id: "t1", content: "file contents", is_error: false}
             ]

      # A second update with the same id does NOT re-emit call or result.
      {_state, dup} =
        Translator.step(state, %{
          "sessionUpdate" => "tool_call_update",
          "toolCallId" => "t1",
          "status" => "completed",
          "content" => chunk("more")
        })

      assert dup == []
    end

    test "marks the ToolResult as an error on failed/error status" do
      {state, _} =
        Translator.step(Translator.new(), %{
          "sessionUpdate" => "tool_call",
          "toolCallId" => "t1",
          "title" => "Bash",
          "rawInput" => %{"command" => "boom"}
        })

      {_state, events} =
        Translator.step(state, %{
          "sessionUpdate" => "tool_call_update",
          "toolCallId" => "t1",
          "status" => "failed",
          "content" => chunk("nonzero exit")
        })

      assert %Event.ToolResult{id: "t1", content: "nonzero exit", is_error: true} =
               List.last(events)
    end

    test "does not double-emit the ToolCall when it was already emitted by tool_call" do
      # First frame emits the ToolCall (input present).
      {state, [%Event.ToolCall{}]} =
        Translator.step(Translator.new(), %{
          "sessionUpdate" => "tool_call",
          "toolCallId" => "t1",
          "title" => "Read",
          "rawInput" => %{"path" => "/a"}
        })

      # Update only carries a result → just the ToolResult, no second ToolCall.
      {_state, events} =
        Translator.step(state, %{
          "sessionUpdate" => "tool_call_update",
          "toolCallId" => "t1",
          "status" => "completed",
          "content" => chunk("done")
        })

      assert events == [%Event.ToolResult{id: "t1", content: "done", is_error: false}]
    end

    test "an update with no result content emits nothing extra" do
      {state, [%Event.ToolCall{}]} =
        Translator.step(Translator.new(), %{
          "sessionUpdate" => "tool_call",
          "toolCallId" => "t1",
          "title" => "Read",
          "rawInput" => %{"path" => "/a"}
        })

      {_state, events} =
        Translator.step(state, %{
          "sessionUpdate" => "tool_call_update",
          "toolCallId" => "t1",
          "status" => "in_progress"
        })

      assert events == []
    end
  end

  describe "available_commands_update" do
    test "emits a SystemEvent listing command names, dropping nils" do
      {_state, events} =
        Translator.step(Translator.new(), %{
          "sessionUpdate" => "available_commands_update",
          "availableCommands" => [
            %{"name" => "compact"},
            %{"name" => "review"},
            %{"description" => "no name here"}
          ]
        })

      assert events == [
               %Event.SystemEvent{subtype: :available_commands, content: "compact, review"}
             ]
    end

    test "handles a missing availableCommands key" do
      {_state, events} =
        Translator.step(Translator.new(), %{
          "sessionUpdate" => "available_commands_update"
        })

      assert events == [%Event.SystemEvent{subtype: :available_commands, content: ""}]
    end
  end

  describe "plan" do
    test "emits a SystemEvent with JSON-encoded entries" do
      entries = [%{"content" => "step 1", "status" => "pending"}]

      {_state, [event]} =
        Translator.step(Translator.new(), %{
          "sessionUpdate" => "plan",
          "entries" => entries
        })

      assert %Event.SystemEvent{subtype: :plan, content: content} = event
      assert Jason.decode!(content) == entries
    end
  end

  describe "unknown / echo updates" do
    test "drops user_message_chunk and any unknown sessionUpdate" do
      {_state, events} =
        run(Translator.new(), [
          %{"sessionUpdate" => "user_message_chunk", "content" => chunk("our own prompt")},
          %{"sessionUpdate" => "some_future_kind", "data" => 1},
          %{"no_session_update" => true}
        ])

      assert events == []
    end
  end

  describe "finish (end of turn)" do
    test "emits SessionResult with token and cost fields zeroed (known behavior)" do
      {_state, events} = Translator.finish(Translator.new(model: "claude-z"), "end_turn")

      assert [%Event.SessionResult{} = result] = events

      assert result.model == "claude-z"
      assert result.input_tokens == 0
      assert result.output_tokens == 0
      assert result.cache_read_tokens == 0
      assert result.cost_usd == 0.0
      assert result.duration_ms == 0.0
      assert result.num_turns == 1
    end

    test "resets turn-scoped accumulation but keeps the model" do
      {state, _} =
        run(Translator.new(model: "claude-z"), [
          %{"sessionUpdate" => "agent_message_chunk", "content" => chunk("partial")},
          %{
            "sessionUpdate" => "tool_call",
            "toolCallId" => "t1",
            "title" => "Read",
            "rawInput" => %{"path" => "/a"}
          }
        ])

      {state, _} = Translator.finish(state, "end_turn")

      assert state.text == []
      assert state.tools == %{}
      assert state.model == "claude-z"

      # A second turn starts clean: no leftover Text from the previous turn.
      {state, _} =
        Translator.step(state, %{
          "sessionUpdate" => "agent_message_chunk",
          "content" => chunk("turn 2")
        })

      {_state, finish_events} = Translator.finish(state, "end_turn")
      assert %Event.Text{text: "turn 2"} = hd(finish_events)
    end
  end
end
