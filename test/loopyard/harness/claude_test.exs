defmodule Loopyard.Harness.ClaudeTest do
  use ExUnit.Case, async: true

  alias Loopyard.Harness.Claude, as: Backend
  alias Loopyard.Agent.Event

  # Helpers for building SDK structs with enforce_keys
  defp text_block(text), do: %ClaudeCode.Content.TextBlock{type: :text, text: text}

  defp tool_use_block(name, input),
    do: %ClaudeCode.Content.ToolUseBlock{type: :tool_use, id: "tu_1", name: name, input: input}

  defp mcp_tool_use_block(name, server, input),
    do: %ClaudeCode.Content.MCPToolUseBlock{
      type: :mcp_tool_use,
      id: "mtu_1",
      name: name,
      server_name: server,
      input: input
    }

  defp tool_result_block(content, is_error \\ false),
    do: %ClaudeCode.Content.ToolResultBlock{
      type: :tool_result,
      tool_use_id: "tu_1",
      content: content,
      is_error: is_error
    }

  defp mcp_tool_result_block(content, is_error \\ false),
    do: %ClaudeCode.Content.MCPToolResultBlock{
      type: :mcp_tool_result,
      tool_use_id: "mtu_1",
      content: content,
      is_error: is_error
    }

  defp assistant_msg(content_blocks),
    do: %ClaudeCode.Message.AssistantMessage{
      type: :assistant,
      message: %{content: content_blocks},
      session_id: "sess_test"
    }

  defp user_msg(content_blocks),
    do: %ClaudeCode.Message.UserMessage{
      type: :user,
      message: %{content: content_blocks},
      session_id: "sess_test"
    }

  describe "translate/1 — AssistantMessage" do
    test "translates text block to Text event" do
      msg = assistant_msg([text_block("Hello world")])
      assert [%Event.Text{text: "Hello world"}] = Backend.translate(msg)
    end

    test "skips empty text blocks" do
      msg = assistant_msg([text_block("")])
      assert [] = Backend.translate(msg)
    end

    test "translates ToolUseBlock to ToolCall event" do
      msg = assistant_msg([tool_use_block("read_file", %{"path" => "/tmp/x"})])

      assert [%Event.ToolCall{name: "read_file", input: %{"path" => "/tmp/x"}}] =
               Backend.translate(msg)
    end

    test "translates MCPToolUseBlock with server name prefix" do
      msg =
        assistant_msg([mcp_tool_use_block("exec", "loopyard-container", %{"command" => "ls"})])

      assert [
               %Event.ToolCall{
                 name: "mcp__loopyard-container__exec",
                 input: %{"command" => "ls"}
               }
             ] =
               Backend.translate(msg)
    end

    test "handles nil content" do
      msg = assistant_msg(nil)
      assert [] = Backend.translate(msg)
    end

    test "translates multiple content blocks" do
      msg =
        assistant_msg([
          text_block("Let me check"),
          tool_use_block("bash", %{"command" => "ls"})
        ])

      assert [
               %Event.Text{text: "Let me check"},
               %Event.ToolCall{name: "bash", input: %{"command" => "ls"}}
             ] = Backend.translate(msg)
    end
  end

  describe "translate/1 — UserMessage (tool results)" do
    test "translates ToolResultBlock to ToolResult event" do
      msg = user_msg([tool_result_block("file contents here")])

      assert [%Event.ToolResult{content: "file contents here", is_error: false}] =
               Backend.translate(msg)
    end

    test "translates MCPToolResultBlock to ToolResult event" do
      msg = user_msg([mcp_tool_result_block("container output")])

      assert [%Event.ToolResult{content: "container output", is_error: false}] =
               Backend.translate(msg)
    end

    test "translates error tool results" do
      msg = user_msg([tool_result_block("command not found", true)])

      assert [%Event.ToolResult{content: "command not found", is_error: true}] =
               Backend.translate(msg)
    end

    test "skips empty tool results" do
      msg = user_msg([tool_result_block("")])
      assert [] = Backend.translate(msg)
    end

    test "handles text block list content in tool results" do
      msg = user_msg([tool_result_block([text_block("nested text")])])

      assert [%Event.ToolResult{content: "nested text", is_error: false}] =
               Backend.translate(msg)
    end
  end

  describe "translate/1 — ResultMessage" do
    test "returns SessionResult with usage stats" do
      msg = %ClaudeCode.Message.ResultMessage{
        type: :result,
        subtype: :success,
        is_error: false,
        duration_ms: 100.0,
        duration_api_ms: 80.0,
        num_turns: 3,
        session_id: "sess_1",
        total_cost_usd: 0.01,
        usage: %{input_tokens: 1000, output_tokens: 500, cache_read_input_tokens: 200},
        model_usage: %{"claude-sonnet-4-20250514" => %{}}
      }

      assert [%Loopyard.Agent.Event.SessionResult{} = result] = Backend.translate(msg)
      assert result.model == "claude-sonnet-4-20250514"
      assert result.input_tokens == 1000
      assert result.output_tokens == 500
      assert result.cache_read_tokens == 200
      assert result.cost_usd == 0.01
      assert result.num_turns == 3
    end
  end

  describe "translate/1 — unknown messages" do
    test "returns empty list for unrecognized messages" do
      assert [] = Backend.translate(%{unknown: true})
      assert [] = Backend.translate(:something)
    end
  end

  describe "translate/1 — output capping" do
    test "caps tool result content beyond 200 lines" do
      long_output = Enum.map_join(1..250, "\n", &"line #{&1}")
      msg = user_msg([tool_result_block(long_output)])

      [%Event.ToolResult{content: capped}] = Backend.translate(msg)
      assert capped =~ "... (50 lines omitted)"
      assert capped =~ "line 250"
    end
  end
end
