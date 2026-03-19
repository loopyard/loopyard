defmodule BoomLooper.Agent.Backend.ClaudeCode do
  @moduledoc """
  Backend implementation wrapping the `claude_code` hex package (CLI subprocess).
  Translates SDK message types into `BoomLooper.Agent.Event` structs.
  """
  @behaviour BoomLooper.Agent.Backend

  alias BoomLooper.Agent.Event

  @impl true
  def start_session(opts) do
    ClaudeCode.start_link(opts)
  end

  @impl true
  def stream(session, prompt) do
    session
    |> ClaudeCode.stream(prompt, include_partial_messages: true)
    |> Stream.flat_map(&translate/1)
  end

  @impl true
  def stop(session) do
    ClaudeCode.stop(session)
  end

  # --- Translation: SDK messages → BoomLooper events ---

  @doc false
  def translate(%ClaudeCode.Message.AssistantMessage{message: message}) do
    content = message.content || []

    Enum.flat_map(content, fn
      %ClaudeCode.Content.TextBlock{text: text} when text != "" ->
        [%Event.Text{text: text}]

      %ClaudeCode.Content.ToolUseBlock{name: name, input: input} ->
        [%Event.ToolCall{name: name, input: input}]

      %ClaudeCode.Content.MCPToolUseBlock{name: name, server_name: server, input: input} ->
        [%Event.ToolCall{name: "mcp__#{server}__#{name}", input: input}]

      _ ->
        []
    end)
  end

  def translate(%ClaudeCode.Message.PartialAssistantMessage{} = msg) do
    case ClaudeCode.Message.PartialAssistantMessage.extract_text(msg) do
      {:ok, text} -> [%Event.TextDelta{text: text}]
      :error -> []
    end
  end

  def translate(%ClaudeCode.Message.UserMessage{message: %{content: content}})
      when is_list(content) do
    Enum.flat_map(content, fn
      %ClaudeCode.Content.ToolResultBlock{content: result_content, is_error: is_error} ->
        text = extract_text(result_content)
        if text != "", do: [%Event.ToolResult{content: text, is_error: is_error}], else: []

      %ClaudeCode.Content.MCPToolResultBlock{content: result_content, is_error: is_error} ->
        text = extract_text(result_content)
        if text != "", do: [%Event.ToolResult{content: text, is_error: is_error}], else: []

      _ ->
        []
    end)
  end

  # ResultMessage is a summary of the full turn — skip to avoid duplicates.
  def translate(%ClaudeCode.Message.ResultMessage{}), do: []

  def translate(_), do: []

  # --- Helpers ---

  @max_tool_result_lines 200

  defp extract_text(content) when is_binary(content), do: cap_output(content)

  defp extract_text(content) when is_list(content) do
    content
    |> Enum.filter(&match?(%ClaudeCode.Content.TextBlock{}, &1))
    |> Enum.map_join("", & &1.text)
    |> cap_output()
  end

  defp extract_text(_), do: ""

  defp cap_output(text) do
    lines = String.split(text, "\n")

    if length(lines) > @max_tool_result_lines do
      kept = Enum.take(lines, -@max_tool_result_lines)
      omitted = length(lines) - @max_tool_result_lines
      "... (#{omitted} lines omitted)\n" <> Enum.join(kept, "\n")
    else
      text
    end
  end
end
