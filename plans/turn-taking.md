# Turn-taking — a harness-agnostic abstraction

**Goal:** make turn-taking a first-class, pluggable thing so ACP, the current
Claude Code SDK backend, and future custom harnesses all drive the *same* model.
This unifies three things we've been hand-patching: the pending-send queue, the
`ask_user`/approval blocking brokers, and Stop/interrupt.

## The model (the part that's built)

`Loopyard.Turn` — a **pure** state machine (`lib/loopyard/turn.ex`, tested in
`test/loopyard/turn_test.exs`, 24 tests). It owns *whose turn it is* and what
happens to human input while the agent holds the turn.

**Phases:** `:human` (idle) · `:agent` (holds the turn, streaming) ·
`:agent_blocked` (yielded mid-turn for input — question OR permission, one phase
with a typed `blocked_on` payload).

**Contract:** `step(turn, event) :: {:ok, turn, [effect]} | {:error, reason}`,
pure, no I/O. Effects the caller runs:

| effect | ClaudeCode SDK | ACP |
|---|---|---|
| `{:start_turn, prompt}` | `backend.stream(session, prompt)` | `session/prompt` |
| `{:answer_input, id, decision}` | reply the ask/approval broker | `session/request_permission` response |
| `:cancel_turn` | stop (today: kill+restart) | `session/cancel` |
| `{:queued, text}` | UI feedback | UI feedback |

Key behaviors: a `:send` while `:agent`/`:agent_blocked` **parks** in the queue
(no stream pollution); on `:turn_complete` a parked flurry **batch-drains into
one** next turn; `:interrupt` cancels + drops the queue + yields to `:human`.

## Why this is the right seam

- **ACP** is *designed* on this model — one `session/prompt` per turn, streamed
  `session/update`, `session/cancel` to interrupt, no concurrent prompts. The
  mapping is 1:1.
- **Custom harnesses** implement the same handful of effects; the machine
  doesn't care how they work inside.
- The three ACP review gaps (permission dropped at StreamHandler, no
  `session/cancel`, the messy brokers) all collapse into `:agent_blocked` +
  `{:answer_input, ...}` + `:cancel_turn`.

## Build order

1. **The pure machine** — ✅ done (`Loopyard.Turn` + tests).
2. **Extend the `Backend` behaviour** with `answer_input(session, id, decision)`
   and `cancel_turn(session)`. Implement for ACP (`session/request_permission`
   reply + `session/cancel`) and ClaudeCode (broker reply; stop).
3. **Drive the machine from `ChatAgent`** — hold a `%Turn{}` in state; route
   `send_message`/`stream_done`/Stop/answer through `Turn.step/2` and run the
   effects. `status` becomes a projection of `turn.phase`; `pending_sends`
   becomes `turn.queue`.
4. **Surface `:agent_blocked` via the existing card UI** — `StreamHandler` maps
   ACP `%Event.PermissionRequest{}` (and the SDK's `ask_user`) to
   `{:input_requested, kind, id, payload}`; the card's answer →
   `{:answer, id, decision}`; Stop → `:interrupt`.
5. **Retire** the standalone `Harness.Questions`/`Harness.Approvals` blocking
   brokers onto the machine (they become the UI projection of `:agent_blocked`).

Steps 2–5 each ship independently. The pure machine (1) lets us write all the
transition logic and tests with zero runtime risk before touching the live
chat path.
