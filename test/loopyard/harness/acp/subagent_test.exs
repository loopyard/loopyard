defmodule Loopyard.Harness.ACP.SubagentTest do
  @moduledoc """
  How a harness-native sub-agent (Claude Code's `Task`/`Agent` tool) shows up
  on the ACP wire, and what the Translator makes of it. The frame shapes are
  trimmed verbatim from a live capture against claude-agent-acp 0.76.0 /
  Claude Code 2.1.268 (2026-10-21) — see docs/ARCHITECTURE.md
  "Sub-agents inside the harness".

  Two shapes exist:

    * FOREGROUND (`run_in_background: false`): the Agent call stays open while
      the sub-agent's own tool calls stream, each stamped with
      `_meta.claudeCode.parentToolUseId`; the sub-agent's final report arrives
      as the Agent call's `tool_call_update` content.
    * BACKGROUND (the CLI's default): the Agent call completes at once with an
      internal "Async agent launched" result; the nested calls still carry the
      parent id, but the report never comes back on the call — the CLI feeds
      it to the parent as a task-notification turn.
  """
  use ExUnit.Case, async: true

  alias Loopyard.Harness.ACP.Translator
  alias Loopyard.Agent.Event

  @parent "toolu_01Te4hu3HdBfkfCpzw9ApaJk"

  defp run(state, updates) do
    Enum.reduce(updates, {state, []}, fn update, {st, acc} ->
      {st, events} = Translator.step(st, update)
      {st, acc ++ events}
    end)
  end

  defp agent_meta(extra \\ %{}),
    do: %{"claudeCode" => Map.merge(%{"toolName" => "Agent", "subagent" => true}, extra)}

  defp child_meta(tool),
    do: %{"claudeCode" => %{"toolName" => tool, "parentToolUseId" => @parent}}

  # The Agent call as the adapter streams it: title-only first, then the
  # arguments in fragments.
  defp agent_call_frames do
    [
      %{
        "sessionUpdate" => "tool_call",
        "toolCallId" => @parent,
        "title" => "Task",
        "kind" => "think",
        "status" => "pending",
        "rawInput" => %{},
        "_meta" => agent_meta()
      },
      %{
        "sessionUpdate" => "tool_call_update",
        "toolCallId" => @parent,
        "title" => "Find callers of greet function",
        "kind" => "think",
        "rawInput" => %{"description" => "Find callers of greet function"},
        "_meta" => agent_meta()
      },
      # The prompt fragment also ECHOES the prompt as `content` — it is not a
      # result (there is no status), and must not be mistaken for one.
      %{
        "sessionUpdate" => "tool_call_update",
        "toolCallId" => @parent,
        "rawInput" => %{
          "description" => "Find callers of greet function",
          "subagent_type" => "Explore",
          "prompt" => "Find every caller of greet."
        },
        "content" => [
          %{
            "type" => "content",
            "content" => %{"type" => "text", "text" => "Find every caller of greet."}
          }
        ],
        "_meta" => agent_meta()
      }
    ]
  end

  defp child_frames(id, command, output) do
    [
      %{
        "sessionUpdate" => "tool_call",
        "toolCallId" => id,
        "title" => command,
        "kind" => "execute",
        "status" => "pending",
        "rawInput" => %{"command" => command},
        "_meta" => child_meta("Bash")
      },
      %{
        "sessionUpdate" => "tool_call_update",
        "toolCallId" => id,
        "status" => "completed",
        "content" => [
          %{
            "type" => "content",
            "content" => %{"type" => "text", "text" => "```console\n#{output}\n```"}
          }
        ],
        "_meta" => child_meta("Bash")
      }
    ]
  end

  describe "the Agent call" do
    test "is a kind: :agent ToolCall refined as its arguments stream in — never a result" do
      {_state, events} = run(Translator.new(), agent_call_frames())

      # Every frame refines the SAME call (StreamHandler merges by id); none
      # of them is a ToolResult (the prompt echo is not a report).
      assert events != []

      assert Enum.all?(
               events,
               &match?(
                 %Event.ToolCall{id: @parent, name: "Agent", kind: :agent, parent_id: nil},
                 &1
               )
             )

      assert %Event.ToolCall{input: input} = List.last(events)
      assert input["description"] == "Find callers of greet function"
      assert input["subagent_type"] == "Explore"
      assert input["prompt"] == "Find every caller of greet."
    end
  end

  describe "the sub-agent's own calls" do
    test "carry the Agent call's id as parent_id (the adapter's parentToolUseId)" do
      {state, _} = run(Translator.new(), agent_call_frames())
      {_state, events} = run(state, child_frames("toolu_child1", "pwd", "/workspace"))

      assert [
               %Event.ToolCall{id: "toolu_child1", name: "Bash", parent_id: @parent, kind: nil},
               %Event.ToolResult{id: "toolu_child1", content: "/workspace", is_error: false}
             ] = events
    end

    test "a top-level call has no parent_id" do
      {_state, events} =
        run(Translator.new(), [
          %{
            "sessionUpdate" => "tool_call",
            "toolCallId" => "t1",
            "title" => "ls",
            "rawInput" => %{"command" => "ls"},
            "_meta" => %{"claudeCode" => %{"toolName" => "Bash"}}
          }
        ])

      assert [%Event.ToolCall{id: "t1", parent_id: nil}] = events
    end
  end

  describe "foreground sub-agent (run_in_background: false)" do
    test "the Agent call's result IS the sub-agent's final report" do
      {state, _} = run(Translator.new(), agent_call_frames())
      {state, _} = run(state, child_frames("toolu_child1", "pwd", "/workspace"))

      {state, events} =
        run(state, [
          # The completion arrives in two frames: toolResponse metadata first…
          %{
            "sessionUpdate" => "tool_call_update",
            "toolCallId" => @parent,
            "_meta" => %{
              "claudeCode" => %{
                "toolName" => "Agent",
                "toolResponse" => %{
                  "status" => "completed",
                  "prompt" => "Find every caller of greet."
                }
              }
            }
          },
          # …then the report as the call's content.
          %{
            "sessionUpdate" => "tool_call_update",
            "toolCallId" => @parent,
            "status" => "completed",
            "content" => [
              %{
                "type" => "content",
                "content" => %{
                  "type" => "text",
                  "text" => "## Report\n\n- lib/app.rb:2\n- bin/run:3"
                }
              }
            ],
            "_meta" => %{"claudeCode" => %{"toolName" => "Agent"}}
          }
        ])

      assert [%Event.ToolResult{id: @parent, content: "## Report\n\n- lib/app.rb:2\n- bin/run:3"}] =
               events

      # Nothing left to close at the end of the turn.
      {_state, finish_events} = Translator.finish(state)
      assert [%Event.SessionResult{}] = finish_events
    end
  end

  describe "background sub-agent (the CLI's default)" do
    # The adapter's completion frames for an async launch, verbatim shape.
    defp async_launch_frames do
      [
        %{
          "sessionUpdate" => "tool_call_update",
          "toolCallId" => @parent,
          "_meta" => %{
            "claudeCode" => %{
              "toolName" => "Agent",
              "toolResponse" => %{
                "isAsync" => true,
                "status" => "async_launched",
                "agentId" => "a5974198a91633484",
                "resolvedModel" => "claude-sonnet-5",
                "outputFile" => "/tmp/claude-0/-workspace/sess/tasks/a5974198a91633484.output"
              }
            }
          }
        },
        %{
          "sessionUpdate" => "tool_call_update",
          "toolCallId" => @parent,
          "status" => "completed",
          "content" => [
            %{
              "type" => "content",
              "content" => %{
                "type" => "text",
                "text" =>
                  "Async agent launched successfully. (This tool result is internal metadata — never quote or paste any part of it…)\nagentId: a5974198a91633484"
              }
            }
          ],
          "_meta" => %{"claudeCode" => %{"toolName" => "Agent"}}
        }
      ]
    end

    test "the internal 'async launched' result is NOT surfaced; the call stays open" do
      {state, _} = run(Translator.new(), agent_call_frames())
      {_state, events} = run(state, async_launch_frames())
      # Only the call's refinement with the model it resolved to — no result.
      refute Enum.any?(events, &match?(%Event.ToolResult{}, &1))
      assert [%Event.ToolCall{id: @parent}] = events
    end

    test "nested calls still land under the parent after the launch frames" do
      {state, _} = run(Translator.new(), agent_call_frames() ++ async_launch_frames())

      {_state, events} =
        run(state, child_frames("toolu_child2", "grep -rn greet", "lib/app.rb:2"))

      assert [%Event.ToolCall{id: "toolu_child2", parent_id: @parent}, %Event.ToolResult{}] =
               events
    end

    test "the turn's end closes the open background call so the card never sticks" do
      {state, _} = run(Translator.new(), agent_call_frames() ++ async_launch_frames())
      {_state, events} = Translator.finish(state)

      assert [
               %Event.ToolResult{id: @parent, content: content, is_error: false},
               %Event.SessionResult{}
             ] =
               events

      assert content =~ "background"
    end

    test "an interrupted turn closes it as an error" do
      {state, _} = run(Translator.new(), agent_call_frames() ++ async_launch_frames())
      {_state, events} = Translator.finish(state, {:error, "cancelled"})

      assert [
               %Event.ToolResult{id: @parent, is_error: true},
               %Event.SessionResult{is_error: true}
             ] = events
    end
  end

  describe "the model the sub-agent ran on" do
    # Claude Code's Agent tool output schema carries `resolvedModel` (and
    # `modelsUsed` after a mid-run swap); the adapter forwards it verbatim as
    # `_meta.claudeCode.toolResponse` on a tool_call_update.
    test "a background launch's resolvedModel re-emits the call with the model" do
      {state, _} = run(Translator.new(), agent_call_frames())
      {_state, events} = run(state, async_launch_frames())

      assert [%Event.ToolCall{id: @parent, kind: :agent, model: "claude-sonnet-5"}] = events
    end

    test "a foreground completion names it too; modelsUsed's last entry wins" do
      {state, _} = run(Translator.new(), agent_call_frames())

      {_state, events} =
        run(state, [
          %{
            "sessionUpdate" => "tool_call_update",
            "toolCallId" => @parent,
            "_meta" => %{
              "claudeCode" => %{
                "toolName" => "Agent",
                "toolResponse" => %{
                  "status" => "completed",
                  "resolvedModel" => "claude-opus-5",
                  "modelsUsed" => ["claude-opus-5", "claude-haiku-4-5-20251001"]
                }
              }
            }
          }
        ])

      assert [%Event.ToolCall{id: @parent, model: "claude-haiku-4-5-20251001"}] = events
    end

    test "unreported → no model, and a child call never carries one" do
      {state, events} = run(Translator.new(), agent_call_frames())
      assert Enum.all?(events, &(&1.model == nil))

      {_state, events} = run(state, child_frames("toolu_child1", "pwd", "/workspace"))
      assert [%Event.ToolCall{model: nil}, %Event.ToolResult{}] = events
    end
  end

  describe "adapter 0.108: a delegation carries no `subagent` marker" do
    # Trimmed verbatim from a live capture: claude-agent-acp 0.108.0 / bundled
    # Claude Code 2.1.326 (2026-11-17). The session ran on Haiku 5.5.
    @id "toolu_015TUWmPmXAH9EEWp6WC5PpR"
    @meta %{"claudeCode" => %{"toolName" => "Agent"}}
    @frames [
      %{
        "sessionUpdate" => "tool_call",
        "toolCallId" => @id,
        "_meta" => @meta,
        "name" => "Agent",
        "rawInput" => %{},
        "status" => "pending",
        "title" => "Task",
        "kind" => "think",
        "content" => []
      },
      %{
        "sessionUpdate" => "tool_call_update",
        "toolCallId" => @id,
        "_meta" => @meta,
        "rawInput" => %{"description" => "Reply with ok"},
        "title" => "Reply with ok"
      },
      %{
        "sessionUpdate" => "tool_call_update",
        "toolCallId" => @id,
        "_meta" => @meta,
        "rawInput" => %{
          "description" => "Reply with ok",
          "prompt" => "Reply with exactly the word ok.",
          "subagent_type" => "general-purpose"
        },
        "content" => [
          %{
            "type" => "content",
            "content" => %{"type" => "text", "text" => "Reply with exactly the word ok."}
          }
        ]
      },
      %{
        "sessionUpdate" => "tool_call_update",
        "toolCallId" => @id,
        "_meta" => %{
          "claudeCode" => %{
            "toolName" => "Agent",
            "toolResponse" => %{
              "isAsync" => true,
              "status" => "async_launched",
              "agentId" => "a8a7929a4911f9e2d",
              "description" => "Reply with ok",
              "resolvedModel" => "claude-haiku-5-5",
              "prompt" => "Reply with exactly the word ok."
            }
          }
        }
      },
      %{
        "sessionUpdate" => "tool_call_update",
        "toolCallId" => @id,
        "_meta" => @meta,
        "status" => "completed",
        "rawOutput" => [%{"type" => "text", "text" => "Async agent launched successfully."}],
        "content" => [
          %{
            "type" => "content",
            "content" => %{"type" => "text", "text" => "Async agent launched successfully."}
          }
        ]
      }
    ]

    test "it is still a delegation: stamped, named for its model, and held open" do
      {_state, events} = run(Translator.new(), @frames)

      calls = Enum.filter(events, &match?(%Event.ToolCall{}, &1))
      assert Enum.all?(calls, &(&1.kind == :agent))
      assert %Event.ToolCall{id: @id, model: "claude-haiku-5-5"} = List.last(calls)

      # Neither the echoed prompt nor the launch receipt is its report.
      refute Enum.any?(events, &match?(%Event.ToolResult{}, &1))
    end
  end
end
