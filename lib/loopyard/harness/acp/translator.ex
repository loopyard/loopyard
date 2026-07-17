defmodule Loopyard.Harness.ACP.Translator do
  @moduledoc """
  Pure, stateful translation of ACP `session/update` notifications into
  `Loopyard.Agent.Event` structs — the neutral vocabulary the whole
  Loopyard multiplayer stack already renders.

  It's a *reducer* rather than a per-message function because three things
  need turn-scoped state:

    * **Text finalization.** ACP streams only `agent_message_chunk` deltas;
      there is no "final full message" frame. We accumulate the chunks and,
      on `finish/2`, emit one `%Event.Text{}` so `StreamHandler` commits and
      persists the assistant message (the live `TextDelta`s are display-only
      and would vanish on refresh without this — same partial/final split the
      ClaudeCode backend uses).

    * **Tool-call dedup.** A single tool call surfaces across multiple
      `tool_call` / `tool_call_update` frames (title fills in, then status,
      then result). We emit exactly one `%Event.ToolCall{}` and at most one
      `%Event.ToolResult{}` per `toolCallId`.

    * **End-of-turn accounting.** `finish/2` emits a `%Event.SessionResult{}`
      so token/cost accounting and `claude_session_id` capture fire. NOTE:
      claude-code-acp does not surface token usage today, so token fields are
      0 — see the cost-visibility open decision (#11).

  Usage:

      state = Translator.new(model: "claude-...")
      {state, events} = Translator.step(state, update_map)   # per session/update.update
      {state, events} = Translator.finish(state, stop_reason) # on session/prompt result
  """

  alias Loopyard.Agent.Event

  defstruct text: [], model: nil, tools: %{}

  @type t :: %__MODULE__{text: iodata(), model: String.t() | nil, tools: map()}

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{model: Keyword.get(opts, :model)}
  end

  @doc """
  Translate one ACP `session/update`'s `update` map into events, advancing state.
  """
  @spec step(t(), map()) :: {t(), [Event.t()]}
  def step(state, %{"sessionUpdate" => kind} = update), do: do_step(state, kind, update)
  def step(state, _other), do: {state, []}

  # Streaming assistant text — accumulate for the final Text, emit a live delta.
  defp do_step(state, "agent_message_chunk", update) do
    text = dig_text(update["content"])

    if text == "" do
      {state, []}
    else
      {%{state | text: [state.text, text]}, [%Event.TextDelta{text: text}]}
    end
  end

  # Streaming thinking — display-only, not part of the committed message.
  defp do_step(state, "agent_thought_chunk", update) do
    text = dig_text(update["content"])
    if text == "", do: {state, []}, else: {state, [%Event.ThinkingDelta{thinking: text}]}
  end

  # A tool call surfaces across several frames: the first may carry an empty
  # `rawInput` (just the title), with the real input arriving in a later
  # frame. StreamHandler can't update a tool message after the fact, so we
  # *buffer* the call and emit `ToolCall` only once its input is known (or an
  # update/result forces it out).
  defp do_step(state, "tool_call", update) do
    id = update["toolCallId"]
    {state, entry} = buffer_tool(state, id, update)
    maybe_emit_call(state, id, entry)
  end

  defp do_step(state, "tool_call_update", update) do
    id = update["toolCallId"]
    {state, entry} = buffer_tool(state, id, update)

    # Ensure the call is emitted before its result (force it out if needed).
    {state, call_events} =
      if entry.emitted_call do
        {state, []}
      else
        entry = %{entry | emitted_call: true}

        {put_tool(state, id, entry),
         [%Event.ToolCall{id: id, name: entry.name || "tool", input: entry.input}]}
      end

    entry = state.tools[id]
    result_text = dig_text(update["content"])

    {state, result_events} =
      if not entry.result and result_text != "" do
        entry = %{entry | result: true}
        is_error = update["status"] in ["failed", "error"]

        {put_tool(state, id, entry),
         [%Event.ToolResult{id: id, content: result_text, is_error: is_error}]}
      else
        {state, []}
      end

    {state, call_events ++ result_events}
  end

  # Slash commands / skills available this session (surface for #8); not chat noise.
  defp do_step(state, "available_commands_update", update) do
    names =
      (update["availableCommands"] || [])
      |> Enum.map(& &1["name"])
      |> Enum.reject(&is_nil/1)

    {state, [%Event.SystemEvent{subtype: :available_commands, content: Enum.join(names, ", ")}]}
  end

  defp do_step(state, "plan", update) do
    {state, [%Event.SystemEvent{subtype: :plan, content: Jason.encode!(update["entries"] || [])}]}
  end

  # user_message_chunk (echo of our own prompt) and any unknown update: drop.
  defp do_step(state, _kind, _update), do: {state, []}

  @doc """
  Flush end-of-turn events: the accumulated full assistant `Text` (so the
  message is committed/persisted) and a `SessionResult` for accounting +
  session-id capture.
  """
  @spec finish(t(), nil | {:error, term()}) :: {t(), [Event.t()]}
  def finish(state, error \\ nil) do
    full = IO.iodata_to_binary(state.text)

    text_events = if full == "", do: [], else: [%Event.Text{text: full}]

    # Thread the turn's error status into SessionResult.is_error — that's what
    # drives the bounded auto-retry and the WHY/CONSEQUENCE/ACTION error
    # surface upstream. Without it a failed ACP turn looked like a clean, $0
    # success and the user got silence.
    {is_error, subtype} =
      case error do
        {:error, sub} when is_binary(sub) -> {true, sub}
        {:error, sub} -> {true, inspect(sub)}
        _ -> {false, nil}
      end

    # claude-code-acp surfaces no usage numbers (#11), which froze the UI's
    # token counter at 0 forever. Until the adapter reports real usage,
    # ESTIMATE output from the turn's assembled text (~4 chars/token) so the
    # cumulative counter genuinely racks up turn over turn. Input stays 0 —
    # we have nothing honest to estimate it from.
    result = %Event.SessionResult{
      model: state.model,
      input_tokens: 0,
      output_tokens: div(byte_size(full), 4),
      cache_read_tokens: 0,
      cost_usd: 0.0,
      duration_ms: 0.0,
      num_turns: 1,
      is_error: is_error,
      error_subtype: subtype
    }

    # Reset turn-scoped accumulation; keep model.
    {%{state | text: [], tools: %{}}, text_events ++ [result]}
  end

  # --- helpers ---

  # Merge the latest name/input for a tool id, preferring non-empty input.
  defp buffer_tool(state, id, update) do
    entry = state.tools[id] || %{emitted_call: false, result: false, name: nil, input: %{}}
    input = update["rawInput"] || %{}

    entry = %{
      entry
      | name: tool_name(update) || entry.name,
        input: if(map_size(input) > 0, do: input, else: entry.input)
    }

    {put_tool(state, id, entry), entry}
  end

  # Emit a ToolCall once we know its input; otherwise keep buffering.
  defp maybe_emit_call(state, _id, %{emitted_call: true}), do: {state, []}

  defp maybe_emit_call(state, id, entry) do
    if map_size(entry.input) > 0 do
      entry = %{entry | emitted_call: true}

      {put_tool(state, id, entry),
       [%Event.ToolCall{id: id, name: entry.name || "tool", input: entry.input}]}
    else
      {state, []}
    end
  end

  defp put_tool(state, id, entry), do: %{state | tools: Map.put(state.tools, id, entry)}

  # tool name: prefer Claude's internal tool name, fall back to ACP title/kind.
  # May be nil (a later frame shouldn't clobber an earlier good name); callers
  # default to "tool" only at emit time.
  defp tool_name(update) do
    get_in(update, ["_meta", "claudeCode", "toolName"]) || update["title"] || update["kind"]
  end

  # ACP content can be a single block, a list of blocks, or nested
  # `%{"content" => %{"text" => ...}}`. Dig out concatenated text robustly.
  defp dig_text(nil), do: ""
  defp dig_text(%{"type" => "text", "text" => text}) when is_binary(text), do: text
  defp dig_text(%{"text" => text}) when is_binary(text), do: text
  defp dig_text(%{"content" => inner}), do: dig_text(inner)
  defp dig_text(list) when is_list(list), do: list |> Enum.map_join("", &dig_text/1)
  defp dig_text(_), do: ""
end
