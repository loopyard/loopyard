defmodule Loopyard.Agent.ToolKindTest do
  use ExUnit.Case, async: true

  alias Loopyard.Agent.ToolKind

  test "Claude Code's native tools classify by kind" do
    assert ToolKind.classify("Bash") == :command
    assert ToolKind.classify("Read") == :read
    assert ToolKind.classify("Grep") == :grep
    assert ToolKind.classify("Edit") == :edit
    assert ToolKind.classify("Write") == :write
  end

  test "loopyard MCP tools classify by kind" do
    assert ToolKind.classify("mcp__loopyard-container__exec") == :command
    assert ToolKind.classify("mcp__loopyard-container__read_file") == :read
    assert ToolKind.classify("mcp__loopyard-container__file_url") == :plumbing
  end

  test "a harness-native sub-agent delegation is :agent (both of Claude Code's names)" do
    assert ToolKind.classify("Agent") == :agent
    assert ToolKind.classify("Task") == :agent
  end

  test "unknown names and nil degrade to :generic" do
    assert ToolKind.classify("SomethingNew") == :generic
    assert ToolKind.classify(nil) == :generic
  end
end
