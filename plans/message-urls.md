# Plan: Message URLs

## The idea

Every chat message gets a permanent URL. Open it in a new tab and you see:
- Static messages (assistant text, tool results) → rendered HTML page with the content
- Streaming messages (exec_stream, build output) → live-updating page, streams in real-time
- All pages have a "raw text" link for plain text copy

This enables:
- **Tailing** — tear off a streaming command into its own tab/window
- **Sharing** — send someone a link to a specific tool result or agent response
- **Multi-monitor** — spread different outputs across windows
- **Debugging** — link to the exact error output when asking for help

## Current problems

1. **Message indices are unreliable** — the LiveView adds synthetic build messages to `@messages` that don't exist in ETS at the same index. When MessageLive loads by index, it gets the wrong message or "not found".

2. **Streaming doesn't sync on refresh** — build/stream messages are only in the LiveView socket, not reliably in ETS. Refreshing the MessageLive page shows nothing.

3. **Dual-write pattern** — exec_stream writes directly to ETS AND broadcasts to LiveView. These get out of sync.

## Solution: Message IDs instead of indices

Stop using array indices. Give each message a unique ID.

```elixir
%{
  id: "msg_abc123",
  role: :assistant,
  content: "...",
  timestamp: DateTime.utc_now()
}
```

**URLs become**: `/p/:project_id/b/:branch_id/chat/:agent_id/msg/:msg_id`

No more index-based lookup. No more sync issues. The ID is stable regardless of what other messages exist.

### Message storage

One source of truth: the agent's ETS state. ALL messages go through `ChatAgent.append_message/2` — including build/stream messages. No direct ETS writes from tools.

For streaming messages, `append_message` is called once to create the message, then `update_message/2` updates its content as data streams in:

```elixir
# Start streaming
ChatAgent.append_message(agent_id, %{id: id, role: :stream, title: "ping google.com", content: "", streaming: true})

# Data arrives
ChatAgent.update_message(agent_id, msg_id, fn msg -> %{msg | content: msg.content <> data} end)

# Done
ChatAgent.update_message(agent_id, msg_id, fn msg -> %{msg | streaming: false} end)
```

### MessageLive

```elixir
def mount(%{"msg_id" => msg_id}, ...) do
  msg = ChatAgent.get_message(agent_id, msg_id)
  if msg.streaming, do: ChatAgent.subscribe(agent_id)
  # renders content, updates on PubSub
end
```

### Signed URLs

Token signs the `agent_id:msg_id` pair (not index). Valid for 24 hours (longer TTL since IDs are stable).

### Migration path

1. Add `:id` field to all messages in `append_message`
2. Add `ChatAgent.get_message/2` and `ChatAgent.update_message/3`
3. Update `msg_url` to use message ID
4. Update OutputController/MessageLive to look up by ID
5. Update exec_stream to use append_message + update_message
6. Remove all direct ETS writes from tools
7. Remove index-based lookup

## Implementation order

1. Add message IDs to append_message
2. Add get_message/update_message to ChatAgent
3. Update signed URL generation
4. Update MessageLive to use message IDs
5. Update OutputController to use message IDs
6. Rewrite exec_stream to use ChatAgent.update_message
7. Remove direct ETS writes from tools
8. Test: open message URL, refresh, see content
9. Test: open streaming message URL, see live updates
10. Test: two tabs watching same streaming message
