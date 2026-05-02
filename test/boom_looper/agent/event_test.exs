defmodule BoomLooper.Agent.EventTest do
  use ExUnit.Case, async: true

  alias BoomLooper.Agent.Event

  describe "TextDelta" do
    test "creates struct with text" do
      delta = %Event.TextDelta{text: "hello"}
      assert delta.text == "hello"
    end
  end

  describe "Text" do
    test "creates struct with text" do
      text = %Event.Text{text: "full message"}
      assert text.text == "full message"
    end
  end

  describe "ToolCall" do
    test "creates struct with name and input" do
      call = %Event.ToolCall{id: "tc_1", name: "read_file", input: %{"path" => "/tmp"}}
      assert call.id == "tc_1"
      assert call.name == "read_file"
      assert call.input == %{"path" => "/tmp"}
    end

    test "id defaults to nil" do
      call = %Event.ToolCall{name: "exec", input: %{}}
      assert call.id == nil
    end
  end

  describe "ToolResult" do
    test "creates struct with content" do
      result = %Event.ToolResult{id: "tc_1", content: "ok", is_error: false}
      assert result.content == "ok"
      refute result.is_error
    end

    test "is_error defaults to false" do
      result = %Event.ToolResult{content: "output"}
      refute result.is_error
    end
  end
end
