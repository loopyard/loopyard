defmodule Loopyard.Agent.Backend.ClaudeCode do
  @moduledoc """
  Backend implementation wrapping the `claude_code` hex package (CLI subprocess).
  Translates SDK message types into `Loopyard.Agent.Event` structs.
  """
  @behaviour Loopyard.Agent.Backend

  alias Loopyard.Agent.Event

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

  @impl true
  def cancel_turn(session) do
    # Interrupt the in-flight query WITHOUT killing the session — the CLI stops
    # generating and emits a result, leaving the session warm to continue the
    # conversation. This is the clean "Stop" (vs. stop/1 which tears it down).
    if is_pid(session) and Process.alive?(session) do
      try do
        ClaudeCode.Session.interrupt(session)
      catch
        :exit, reason -> {:error, reason}
      end
    else
      :ok
    end
  end

  @impl true
  def session_alive?(session) do
    is_pid(session) && Process.alive?(session)
  end

  @impl true
  def session_id(session) do
    # The SDK Session GenServer captures the CLI's session_id from the
    # first AssistantMessage/ResultMessage and then feeds it back on
    # subsequent queries so the CLI continues the same conversation.
    # We mirror it onto ChatAgent state so it outlives the Session pid:
    # see `ChatAgent.init_resume` + `start_session` — every new Claude
    # process we spawn is passed `resume: <session_id>`.
    if is_pid(session) and Process.alive?(session) do
      try do
        ClaudeCode.Session.session_id(session)
      catch
        :exit, _ -> nil
      end
    else
      nil
    end
  end

  # --- Translation: SDK messages → Loopyard events ---

  @doc false
  def translate(%ClaudeCode.Message.AssistantMessage{message: message}) do
    content = message.content || []

    Enum.flat_map(content, fn
      %ClaudeCode.Content.TextBlock{text: text} when text != "" ->
        [%Event.Text{text: text}]

      %ClaudeCode.Content.ThinkingBlock{thinking: thinking} when thinking != "" ->
        [%Event.Thinking{thinking: thinking}]

      %ClaudeCode.Content.ToolUseBlock{name: name, input: input} ->
        [%Event.ToolCall{name: name, input: input}]

      %ClaudeCode.Content.MCPToolUseBlock{name: name, server_name: server, input: input} ->
        [%Event.ToolCall{name: "mcp__#{server}__#{name}", input: input}]

      %ClaudeCode.Content.ServerToolUseBlock{name: name, input: input} ->
        [%Event.ServerTool{name: name, input: input}]

      _ ->
        []
    end)
  end

  def translate(%ClaudeCode.Message.PartialAssistantMessage{} = msg) do
    text_events =
      case ClaudeCode.Message.PartialAssistantMessage.extract_text(msg) do
        {:ok, text} -> [%Event.TextDelta{text: text}]
        :error -> []
      end

    thinking_events =
      case ClaudeCode.Message.PartialAssistantMessage.extract_thinking(msg) do
        {:ok, thinking} -> [%Event.ThinkingDelta{thinking: thinking}]
        :error -> []
      end

    text_events ++ thinking_events
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

  def translate(%ClaudeCode.Message.ResultMessage{} = msg) do
    usage = msg.usage || %{}
    model = msg.model_usage |> Map.keys() |> List.first()

    [
      %Event.SessionResult{
        model: model,
        input_tokens: usage[:input_tokens] || 0,
        output_tokens: usage[:output_tokens] || 0,
        cache_read_tokens: usage[:cache_read_input_tokens] || 0,
        cost_usd: msg.total_cost_usd || 0.0,
        duration_ms: msg.duration_ms || 0.0,
        num_turns: msg.num_turns || 0
      }
    ]
  end

  def translate(%ClaudeCode.Message.RateLimitEvent{rate_limit_info: info}) when is_map(info) do
    [
      %Event.RateLimitStatus{
        status: Map.get(info, :status),
        resets_at_ms: Map.get(info, :resets_at),
        utilization: Map.get(info, :utilization),
        rate_limit_type: Map.get(info, :rate_limit_type),
        is_using_overage: Map.get(info, :is_using_overage)
      }
    ]
  end

  def translate(%ClaudeCode.Message.AuthStatusMessage{} = msg) do
    [
      %Event.AuthStatus{
        is_authenticating: msg.is_authenticating,
        error: msg.error,
        output: msg.output || []
      }
    ]
  end

  def translate(msg) do
    cond do
      ClaudeCode.Message.SystemMessage.type?(msg) ->
        subtype = Map.get(msg, :subtype, :unknown)

        content =
          try do
            to_string(msg)
          rescue
            _ -> inspect(msg)
          end

        if content != "" do
          [%Event.SystemEvent{subtype: subtype, content: content}]
        else
          []
        end

      true ->
        []
    end
  end

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
