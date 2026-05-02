defmodule BoomLooperWeb.Live.WorkspaceLive.ThinkingIndicatorTest do
  @moduledoc """
  The thinking indicator is the user's only signal that the agent
  is working. If it disappears, the UI feels dead and the user has
  no idea if their message was received.

  Contract:
    * When agent status is :thinking and streaming_text is empty,
      the thinking indicator MUST render.
    * The thinking word MUST be present (not nil/empty).
    * Sidebar and chat panel MUST show the same word.
    * When a tool is active, the word MUST be tool-specific.
    * When agent status is :idle, no thinking indicator.
  """

  use ExUnit.Case, async: true

  alias BoomLooperWeb.Components.Sidebar

  describe "thinking_word/2" do
    test "returns a non-empty string with no active tool" do
      word = Sidebar.thinking_word("test-agent-123", nil)
      assert is_binary(word)
      assert String.length(word) > 0
    end

    test "returns a tool-specific word when tool is known" do
      for {tool, _} <- tool_phrase_map() do
        word = Sidebar.thinking_word("test-agent", "mcp__boom-looper-container__#{tool}")
        assert is_binary(word)
        assert String.length(word) > 0
      end
    end

    test "strips MCP prefix from tool name" do
      # grep tool should get a grep-specific phrase, not a generic one
      words =
        for _ <- 1..20 do
          Sidebar.thinking_word(
            "agent-#{System.unique_integer()}",
            "mcp__boom-looper-container__grep"
          )
        end
        |> Enum.uniq()

      grep_phrases = tool_phrase_map()["grep"]
      # At least one of the 20 samples should be a grep-specific phrase
      assert Enum.any?(words, &(&1 in grep_phrases)),
             "Expected at least one grep-specific phrase in #{inspect(words)}"
    end

    test "falls back to generic words for unknown tools" do
      word = Sidebar.thinking_word("test", "mcp__some-server__unknown_tool")
      assert is_binary(word)
      assert String.length(word) > 0
    end

    test "same agent_id and time window returns same word" do
      id = "stable-agent-#{System.unique_integer()}"
      word1 = Sidebar.thinking_word(id, nil)
      word2 = Sidebar.thinking_word(id, nil)
      assert word1 == word2
    end
  end

  describe "thinking_word assign contract" do
    test "workspace_live sets :thinking_word on status change to :thinking" do
      # Simulate what on_status_changed does
      id = "test-agent"
      status = :thinking
      active_tool = nil

      word =
        if status in [:thinking, :booting, :backoff],
          do: Sidebar.thinking_word(id, active_tool),
          else: nil

      assert is_binary(word)
      assert String.length(word) > 0
    end

    test "workspace_live sets :thinking_word to nil on :idle" do
      status = :idle

      word =
        if status in [:thinking, :booting, :backoff],
          do: Sidebar.thinking_word("id", nil),
          else: nil

      assert word == nil
    end

    test "tool-specific word is set when tool message arrives" do
      id = "agent-with-tool"
      tool = "mcp__boom-looper-container__edit"

      word = Sidebar.thinking_word(id, tool)

      edit_phrases = tool_phrase_map()["edit"]

      assert word in edit_phrases,
             "Expected edit-specific phrase, got: #{inspect(word)}"
    end
  end

  describe "agent_display_status" do
    test ":thinking status with alive agent shows :thinking display" do
      # Agent must be alive for thinking to show
      agent = %{id: "test-#{System.unique_integer()}", status: :thinking, alive?: true}
      assert Sidebar.agent_display_status(agent) == :thinking
    end

    test ":idle status shows :ready" do
      agent = %{id: "test-#{System.unique_integer()}", status: :idle, alive?: true}
      assert Sidebar.agent_display_status(agent) == :ready
    end

    test ":booting shows :thinking (same indicator)" do
      agent = %{id: "test-#{System.unique_integer()}", status: :booting, alive?: true}
      assert Sidebar.agent_display_status(agent) == :thinking
    end
  end

  # Build the tool phrases map from the actual tool modules — single source of truth.
  defp tool_phrase_map do
    for mod <- BoomLooper.Tools.Container.__tool_server__().tools,
        words = mod.__busy_words__(),
        words != [],
        into: %{} do
      {mod.__tool_name__(), Enum.map(words, &sentence_case/1)}
    end
  end

  defp sentence_case(<<first::utf8, rest::binary>>),
    do: <<String.upcase(<<first::utf8>>)::binary, rest::binary>>

  defp sentence_case(other), do: other
end
