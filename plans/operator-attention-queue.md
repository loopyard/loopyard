# Plan: The Operator Attention Queue — a calm, self-sorting "what needs me"

> Fully specifies the attention view from issue #69. Builds on `plans/operator-hub.md`
> (the operator cockpit + Operator.Digest). Design settled in conversation; this is
> the buildable spec.

## Roles (who's who)

- **Operator = you** (the human running everything).
- **Chief of staff = the agent** (`Loopyard.Operator` / `/operator` in code). Its
  job: surface the important problems, **put them in context for you**, answer
  what it can, and **delegate back to the workspace agents**. It works FOR you.

So "the attention queue" is **a live summary of what YOU need to do**, curated by
the chief of staff — not a status readout.

## The idea (one sentence)

The chief of staff's **right sidebar is a self-sorting priority queue of condensed
cards** — "what needs YOU" — that reshuffles calmly as agents change state, while
your 1:1 chat with the chief of staff stays clean and each workspace's activity
stays in its own stream.

## The core principle: never interlace — three separate things

A single stream of every workspace's activity is a firehose and would defeat the
"chief of staff keeps me calm" point. So we keep three things strictly separate:

1. **The operator message stream = your 1:1 dialogue with the chief of staff.**
   Bounded, calm. Workspace agents' turns NEVER flow into it. It's a conversation,
   not a feed. (The operator *condenses* — it briefs you: "garryslist's done,
   gbrain needs you" — one intentional message, never relaying raw agent streams.)
2. **Each workspace has its own stream** — where that workspace's real activity
   lives. You dive into it on demand; it doesn't leak upward.
3. **The right-sidebar queue is a BOARD, not a STREAM.** Live cards show *status*,
   not *messages*. You GLANCE at a small set of handles; you don't READ an
   interlacing timeline. A board is spatial + bounded (a handful of cards updating
   in place); a stream is temporal + unbounded (the thing that overwhelms).

Same principle that keeps the operator *agent's* context lean (pull headlines,
don't get firehosed) keeps the operator *UI* calm.

## The card

The queue is keyed by **agent**, but a workspace ≈ one agent, so practically it's
one card per active workspace. What the card SHOWS is the important part:

- **Identity = project · workspace**, never "Claude". The model name is noise —
  every agent is Claude. `garryslist · ui-changes`, not `Claude · idle`.
- **Body = where it's at / what it needs from YOU** — framed by the chief of
  staff, NOT a raw green/idle dot. This is the whole value: a card is a
  contextualized ask, e.g.
  - blocked → the question or gate in plain terms: *"needs your call: rebase onto
    main, or merge as-is?"*, *"approve deleting the stale volume?"*
  - finished → *"port fix landed, tests green — ready for your next turn"*
  - working → *"wiring up the auth flow…"* (quiet, low)
  The base content comes from the live signal (the actual question / gate action /
  the workspace's focus descriptor #70); the chief of staff may reword it so it
  reads as *what you need to decide*, not *what state a process is in*.
- **One live, deduplicated card per agent** — NOT one per dispatch or message.
  Dispatch into garryslist three times → still one garryslist card, updating in
  place. Card count = agents you're actively juggling (small by construction).
- **Enters the queue two ways**: you *dispatch* work to it (lights up its card),
  OR its *state* surfaces it (asks a question, finishes, hits a gate). Reads
  (`overview`/`peek`) do NOT mint cards.
- **Either party can jump in.** You tap a card to dive into that agent's chat and
  micro-manage it; the chief of staff can also `dispatch` / act on it for you.

## The ordering engine — a weighted score (tunable dials)

The sort IS the value, and it's a **continuous weighted score**, not rigid tiers:

```
score(ws) = w_urgency · urgency(ws)
          + w_recency · recency(ws)
          + w_waiting · how_long_blocked(ws)   # a question sitting 10 min > just now
          + …
```

The stack sorts by `score` descending; when any signal changes, the score changes
and the card **slides to its new position**. The **weights are dials we WILL
tune** (how much a blocking question outweighs recency, how fast idle decays,
whether a long-waiting question beats a fresh one, …) — so they live in config,
not hardcoded.

The natural result of urgency dominating is these bands, top → bottom:

1. **Blocked** — asked a question, or hit a gate (approval / secret). Something is
   STOPPED until you act.
2. **Finished a turn** — done, waiting for your next turn. Needs you, not blocked.
3. **Working** — in progress, nothing wanted. Quiet background.
4. **Idle** — far down the bottom. NOT removed (you never lose track); it just
   settles low as its recency decays.

Recency breaks ties within a band. But because it's a score, the bands are soft —
a workspace idle-but-just-touched can float above one that finished a while ago,
if we dial recency up. That fiddling is expected.

## The calm reshuffle

Server-driven and nearly free: every state change already fires a PubSub event
(`Events.ChatAgent.StatusChanged`, `Events.Activity`, the `needs_you`/`broken`
signals `WorkspaceTree` derives, the `Operator.Digest` turn-end ring). So the
stack re-sorts itself: a question arrives → that card *slides up* to Blocked; a
turn finishes → it eases into Finished; you clear it → it fades. Smooth reorder
animations, **bounded to the top N**, so it breathes rather than floods.

## Chat × queue: focus vs. priority (what "this" means)

The queue reshuffles by urgency; the conversation must NOT get yanked around with
it. Separate two things that are easy to conflate:

- **Priority order** (the queue) — ambient, reshuffles as scores change. It is NOT
  the referent for "this / that / it."
- **Conversational focus** (what "this" means) — **sticky to the conversation**.
  Set by what you're discussing, tapping a card, diving into an agent, or naming
  one explicitly. It does NOT auto-follow the top of the queue.

So reshuffling never changes "this." Discussing garryslist and gbrain jumps to
Blocked? garryslist is still "this" until you say otherwise.

Make focus visible + stable:
- **A focus chip by the composer / breadcrumb** — `● garryslist · ui-changes` —
  shows exactly what "this" points at right now, regardless of queue order. It's
  the anchor; the focused card also stays highlighted in the queue as it sorts
  (and if it drops below the fold, the chip still holds the reference).
- **Switching focus is explicit** — name it, tap its card, or dive in. The chief
  of staff **confirms the switch** ("switching to gbrain") so the referent is
  never ambiguous.
- **New urgent items are nudges, not hijacks.** Something jumps to Blocked mid-
  conversation → the chief of staff surfaces it as a briefing line ("heads up,
  gbrain hit a gate, needs a decision") WITHOUT changing your focus. You choose to
  switch or keep going. Interruptions are surfaced, never silent context-swaps.

Same "never interlace / pull, don't firehose" principle, applied to attention:
the board moves on its own; your focus only moves when you move it.

### Disambiguating a message ("who is this for?")

Two questions hide in "rebase this": (a) is it for the chief of staff or a
workspace agent, and (b) which agent. Both are smaller than they look:

- **(a) me vs. delegate — mostly resolved by *separation of duties*.** The chief
  of staff structurally can't do a workspace's work (no write_file/compose/volume
  for a project — a deliberate boundary). So per-workspace tasks ("rebase / fix
  the bug / run tests") MUST be delegated; its own tools are orchestration/status
  only. The decision collapses to just "which agent?".
- **(b) which agent — layered, never a wrong guess:**
  1. **Focus chip** (default): "this" is already pinned → dispatch there.
  2. **Disambiguation card** (when unsure): the chief of staff drops a card
     offering the likely targets as buttons — the top queue agents + "handle it
     myself" — one tap, no typing. (This is the dispatcher's "slightly special
     UI".) e.g. *"Send this to → [garryslist] [gbrain] [me]?"*
  3. **Ask in prose** (last resort) if even candidates aren't clear.

So it delegates by default, the chip keeps "this" pinned, and only genuine
ambiguity surfaces a small candidate card. Never a silent wrong guess.

**Cheap by construction — route off the index, never the context.** To decide
"which agent" the chief of staff does NOT hold each agent's context (that would
burn tokens). It routes off the short per-agent focus descriptors (#70) — a
handful of one-liners already in its `overview`/queue. Matching your message
against those is a single inference over what it already has: no extra tool
calls, no chat reads. Full context (`peek_workspace`) is opt-in, pulled only when
it deliberately digs in — never per message. The focus descriptor (#70) is thus
the ROUTING INDEX, not just a human reminder: it must be short + current so the
chief of staff can route the whole fleet from a few hundred tokens.

## Navigation (desktop + mobile, same model)

- **Tap a card → dive into that workspace's own chat.** Reuses Loopyard's
  URL-per-view + tear-off-tabs design (a first-class goal), so nothing new:
  - **Mobile:** full-screen workspace chat; **swipe back** returns to the operator.
  - **Desktop:** live-nav in place (back returns), or open in a new tab to juggle
    several (the multiplayer tear-off model). The card link carries both.
- You **talk to the operator in the main chat** about the queue; the queue is the
  glanceable board beside it.
- **Replaces** the alphabetical workspace-tree board currently in the operator
  rail (`operator_live.ex` `operator_board/1`) — same info, sorted by what needs
  you instead of by name.

## Layout — desktop vs mobile (same model, different framing)

**Build it as an evolution of Loopyard's EXISTING sidebar, not a bespoke panel.**
The god-mode rail already shows projects → workspaces → agents on desktop
(`global_sidebar` / `Birdseye` / `ProjectList.project_groups`) with a working
mobile counterpart (the `Nav.switcher_sheet` bottom sheet). The attention queue is
**that same rail, re-sorted by the weighted urgency score and condensed to
"what needs you"** — each row shows the what-it-needs line instead of a status
dot. Reusing that component family means the desktop-rail + mobile-sheet behavior
(collapse, swipe, sync) is largely inherited, and the queue stays visually
consistent with the rest of the app instead of being a one-off.


- **Desktop:** the stack is a persistent **right rail** beside the operator chat
  (where `operator_board/1` sits today). Always visible, always reshuffling; the
  chat is the main column. On a wide screen a dived-into workspace can open 2-up
  (or a new tab).

- **Mobile:** chat is the full-screen primary — that's the calm 1:1. The stack is
  a **collapsible bottom sheet**, so it's "chat above the stack" but the stack
  only takes the room you give it:
  - **Collapsed (default):** a slim bar pinned above the composer — the single
    top-priority card + a count ("● gbrain needs you · 3 more"). Glanceable, one
    line, doesn't crowd the chat or fight the keyboard.
  - **Pull up:** expands to the full reshuffling stack (blocked → finished →
    working → idle). Triage, then let it drop back down.
  - Tap a card → dive into that workspace full-screen; **swipe back** to the
    operator. Typing to the operator? The sheet stays collapsed so the chat + keyboard own the screen.

  So the vertical order is `chat → (collapsed stack bar) → composer`, and the
  stack grows upward over the chat only when you ask for it. Same self-sorting
  board as desktop; it just starts folded.

## Signals (reuse — nothing new to compute)

- **Blocked** → `needs_you` (question / approval / secret), already derived by
  `WorkspaceTree` + the harness `Approvals`/`Questions`/`SecretRequests` state.
- **Finished** → `StatusChanged → :idle` (turn end); already in `Operator.Digest`.
- **Working** → status in the busy set (`:thinking`, …).
- **Idle** → `:idle`/`:stopped` + last-engaged recency.
- **Last-engaged** → new: last time you dispatched to / opened the workspace
  (distinguishes "actively juggling" from "long idle"). Small ETS field.

## Phases

1. **Queue model** — a pure function: active workspaces → `[%{workspace, tier,
   last_engaged, status}]`, sorted `blocked>finished>working>idle` then recency.
   Computed from `WorkspaceTree` + `Digest` + `Activity` (ETS-cheap, no shell-out).
   Add a `last_engaged` signal (bump on dispatch / on opening a workspace chat).
2. **The queue UI** — the operator right rail renders the sorted live cards with
   smooth reorder (LiveView stream + CSS transition / FLIP), bounded top N;
   replaces `operator_board/1`. Re-sorts on the PubSub events above.
3. **Dive-in nav** — card → workspace chat; mobile swipe-back, desktop nav /
   new-tab. Bump `last_engaged` on open.
4. **Dispatch integration** — `dispatch` lights up / adds the target's card
   (working-set entry point) + bumps `last_engaged`.
5. **Mobile layout** — the queue as a collapsible sheet / overlay + one chat;
   swipe between. Desktop: rail + chat (optionally 2-up on wide).

## Guardrails
- Calm by construction: bounded top N, board-not-stream, smooth reshuffle.
- ETS-cheap reads (the `/workspaces` mount budget — no render-time shell-outs).
- PubSub boundary (`lib/loopyard/events/*` only), StateKeeper owns any ETS table.
- Reuses the operator-hub signals; additive to `plans/operator-hub.md`.
