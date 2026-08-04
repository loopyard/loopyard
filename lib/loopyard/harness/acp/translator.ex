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

  # `break_pending`: a tool call surfaced since the last text chunk, so the next
  # text chunk opens a NEW block and must be separated with a paragraph break.
  # Without it, the assistant's text block BEFORE a tool call and the one AFTER
  # were concatenated with no separator — "…and main." + "No — not merged" came
  # out as "…and main.No — not merged".
  #
  # `used_tokens`: latest context usage from the adapter's `usage_update`
  # notifications (claude-agent-acp; the old claude-code-acp never sends them).
  # Deliberately NOT reset in finish/2 — usage is session-scoped, and the last
  # known value is the honest number for a turn that emitted no update.
  defstruct text: [], model: nil, tools: %{}, break_pending: false, used_tokens: nil

  @type t :: %__MODULE__{
          text: iodata(),
          model: String.t() | nil,
          tools: map(),
          break_pending: boolean(),
          used_tokens: non_neg_integer() | nil
        }

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
  # A paragraph break is prepended when this chunk opens a new block after a
  # tool call (break_pending) so the break lands in BOTH the live delta stream
  # and the committed text — the browser and the persisted message match.
  defp do_step(state, "agent_message_chunk", update) do
    text = dig_text(update["content"])

    if text == "" do
      {state, []}
    else
      sep = if state.break_pending and state.text != [], do: "\n\n", else: ""
      chunk = sep <> text

      {%{state | text: [state.text, chunk], break_pending: false},
       [%Event.TextDelta{text: chunk}]}
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
    {state, events} = maybe_emit_call(state, id, entry)
    # Tool activity now sits between any prior text and the next — the next
    # text chunk opens a fresh block (see break_pending).
    {%{state | break_pending: true}, events}
  end

  defp do_step(state, "tool_call_update", update) do
    id = update["toolCallId"]
    {state, entry} = buffer_tool(state, id, update)

    # Ensure the call is emitted before its result (force it out if needed).
    # If it's ALREADY out and this update brought more of its arguments, emit
    # it again with the fuller input — StreamHandler refines the existing tool
    # message by id rather than recording a second call. Without this, a call
    # announced from its first fragment keeps the husk forever: the transcript
    # shows an Edit with no file and no diff.
    {state, call_events} =
      if entry.emitted_call do
        if input_grew?(state, id, entry) do
          {put_tool(state, id, %{entry | emitted_input: entry.input}),
           [%Event.ToolCall{id: id, name: entry.name || "tool", input: entry.input}]}
        else
          {state, []}
        end
      else
        entry = %{entry | emitted_call: true}

        entry = %{entry | emitted_input: entry.input}

        {put_tool(state, id, entry),
         [%Event.ToolCall{id: id, name: entry.name || "tool", input: entry.input}]}
      end

    entry = state.tools[id]
    raw = dig_text(update["content"])

    {state, result_events} =
      if not entry.result and raw != "" do
        entry = %{entry | result: true}
        {content, wrapped_error?} = clean_result(raw)
        is_error = update["status"] in ["failed", "error"] or wrapped_error?

        {put_tool(state, id, entry),
         [%Event.ToolResult{id: id, content: content, is_error: is_error}]}
      else
        {state, []}
      end

    {%{state | break_pending: true}, call_events ++ result_events}
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

  # Real usage + rate-limit PUSH from the modern adapter (claude-agent-acp).
  # Fires on every assistant-usage change with {used, size}; when the CLI
  # reports a rate_limit_event, the same update additionally carries the full
  # rate_limit_info (camelCase) in _meta["_claude/rateLimit"] — status,
  # resetsAt (ms), utilization, rateLimitType. That's the event-driven signal
  # that replaces blind nil-reset polling: a :rejected here parks the agent
  # with a PRECISELY timed retry.
  defp do_step(state, "usage_update", update) do
    state =
      case update["used"] do
        used when is_integer(used) and used >= 0 -> %{state | used_tokens: used}
        _ -> state
      end

    events =
      case get_in(update, ["_meta", "_claude/rateLimit"]) do
        info when is_map(info) -> [rate_limit_status(info)]
        _ -> []
      end

    {state, events}
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

    # Input tokens: the adapter's `usage_update` (claude-agent-acp) gives us
    # the session's real context usage — report it so StreamHandler's
    # context_utilization actually moves and the 92% proactive compaction
    # fires BEFORE the harness balloons past the container memory cap (#20).
    # Under the legacy adapter (no usage_update) it stays 0 as before.
    # Output: ESTIMATE from the turn's assembled text (~4 chars/token) so the
    # cumulative counter racks up even when the adapter is usage-silent.
    result = %Event.SessionResult{
      model: state.model,
      input_tokens: state.used_tokens || 0,
      output_tokens: div(byte_size(full), 4),
      cache_read_tokens: 0,
      cost_usd: 0.0,
      duration_ms: 0.0,
      num_turns: 1,
      is_error: is_error,
      error_subtype: subtype
    }

    # Reset turn-scoped accumulation; keep model.
    {%{state | text: [], tools: %{}, break_pending: false}, text_events ++ [result]}
  end

  # --- helpers ---

  # Map the adapter-forwarded rate_limit_info (CLI wire shape, camelCase) onto
  # the neutral event. Unknown/missing status degrades to :allowed — never
  # park the agent on a malformed frame.
  defp rate_limit_status(info) do
    status =
      case info["status"] do
        "rejected" -> :rejected
        "allowed_warning" -> :allowed_warning
        _ -> :allowed
      end

    %Event.RateLimitStatus{
      status: status,
      resets_at_ms: if(is_integer(info["resetsAt"]), do: info["resetsAt"]),
      utilization: info["utilization"],
      rate_limit_type: info["rateLimitType"],
      is_using_overage: info["isUsingOverage"]
    }
  end

  # claude-code-acp wraps EVERY tool result for display: the whole thing in a
  # markdown code fence (```…```), and errors additionally in
  # <tool_use_error>…</tool_use_error>. Loopyard renders tool output RAW (it's a
  # console card, not prose), so those wrappers showed up literally — and when
  # the card tail-truncates, the opening ``` scrolled off and left a dangling
  # ```. Strip the OUTER wrapper (only when it wraps the entire content, never a
  # fence that's part of the real output) so the card shows the actual command
  # output. Returns {clean_content, wrapped_in_tool_error?} — the wrapper is
  # itself an error signal, folded into is_error.
  @fence ~r/\A```[^\n]*\n(.*)\n```\z/s
  @tool_err ~r/\A<tool_use_error>\s*(.*?)\s*<\/tool_use_error>\z/s

  defp clean_result(text) do
    unfenced =
      case Regex.run(@fence, String.trim(text)) do
        [_, inner] -> inner
        _ -> text
      end

    case Regex.run(@tool_err, String.trim(unfenced)) do
      [_, inner] -> {inner, true}
      _ -> {unfenced, false}
    end
  end

  # Accumulate name/input for a tool id across updates.
  #
  # ACP delivers `rawInput` in FRAGMENTS as the harness streams the call, and
  # this used to REPLACE the buffered input with whichever fragment arrived
  # last. So an `Edit` whose arguments came as {"file_path"} then
  # {"old_string"} then {"replace_all"} ended up recorded as just
  # `%{"replace_all" => false}` — the identifying arguments dropped on the
  # floor. Measured on a live agent: five consecutive Edit calls, every one
  # stored with the identical one-key input.
  #
  # That fed two visible failures: tool cards showed a call with no file and no
  # diff, and the same-tool-same-input loop guard hashed those identical husks
  # and declared a retry loop over five edits to five DIFFERENT files.
  #
  # Fragments MERGE. A later fragment refines the call; it never was a
  # replacement for it.
  defp buffer_tool(state, id, update) do
    entry =
      state.tools[id] ||
        %{emitted_call: false, result: false, name: nil, input: %{}, emitted_input: %{}}

    input = update["rawInput"] || %{}

    entry = %{
      entry
      | name: tool_name(update) || entry.name,
        input: Map.merge(entry.input, input)
    }

    {put_tool(state, id, entry), entry}
  end

  # Emit a ToolCall once we know its input; otherwise keep buffering.
  defp maybe_emit_call(state, _id, %{emitted_call: true}), do: {state, []}

  defp maybe_emit_call(state, id, entry) do
    if map_size(entry.input) > 0 do
      entry = %{entry | emitted_call: true, emitted_input: entry.input}

      {put_tool(state, id, entry),
       [%Event.ToolCall{id: id, name: entry.name || "tool", input: entry.input}]}
    else
      {state, []}
    end
  end

  # Did this update reveal arguments we hadn't emitted yet?
  defp input_grew?(_state, _id, entry),
    do: entry.input != Map.get(entry, :emitted_input, %{})

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
