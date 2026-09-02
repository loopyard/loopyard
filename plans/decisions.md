# Plan: Decisions — one surface, legible, and not a graveyard

**Status:** plan. Nothing built yet. Written from four complaints, each of which
measured out to something concrete.

## What's actually wrong (measured, not guessed)

**1. The card has no typographic hierarchy — at all.**
Every type declaration in `cards/question.ex` is the same size:

```
$ grep -oE "text-(meta|body|lead|title|hero)" …/cards/question.ex | sort | uniq -c
  11 text-lead
```

Eleven of eleven. The section header, the prompt, each option's label, each
option's description, and the footer all render at one size. Nothing recedes, so
the eye has no anchor and the *differences* between options — which live in the
labels — carry the same weight as the prose explaining them. That is the whole
of "hard to read and tell what is different between these."

**2. The backlog is entirely stale.**
Live attention line right now:

```
[{"1d old", 6}, {"2d old", 3}]
```

Nine pending decisions. **Zero from today.** Earlier in the same session, 16
cards had to be cleared by hand — days old, several pointing at a workspace that
no longer existed. The list has no concept of age, so a two-day-old question a
recycled agent has long since moved past sits with exactly the same urgency as
one asked a minute ago. Overwhelm isn't the count; it's that nothing decays.

**3. One job, three surfaces.**
Per `CLAUDE.md`: the chat shows cards inline, the operator rail *lists* what's
waiting, and the Reviewer (`/review`) clears the backlog one decision per slide.
The rail is a table of contents for a thing that already exists. Two places to
read the same list, and neither is obviously the home.

**4. The phone wants a different verb.**
On a phone the natural motion is **swipe** through decisions, and the natural
follow-up is often **"wait, what do you mean by option 2?"** — which the card
can't express. Today the only exits are Answer and Skip.

## The shape

**The Reviewer is the decisions surface.** `/review` stops being a backlog
mode and becomes *the* place decisions live. The rail keeps a count and an entry
point — a signal, not a second list. Inline chat cards stay exactly as they are:
they're the decision happening in context, which is a different job from
clearing a queue.

### 1. Hierarchy (small, do first)

Three sizes instead of one, per the type scale in `ui-build`:

| Element | Now | Proposed | Why |
|---|---|---|---|
| Section header | `text-lead` | `text-meta` uppercase | It's a label, not content |
| Prompt | `text-lead` | `text-lead` | This is the question — it should dominate |
| Option **label** | `text-lead` | `text-lead` semibold | **The differentiator.** Must be the scan line |
| Option description | `text-lead` | `text-body`, muted | Support, read only after the label narrows it |

On a phone `meta` and `body` both resolve to 17px, so nothing gets small where
it matters — the hierarchy comes from weight and colour there, size on desktop.

### 2. Decay (the overwhelm fix)

Staleness needs to be first-class, in increasing order of cost:

* **Show age on every decision.** "asked 2 days ago" next to a question is often
  all a human needs to skip it.
* **Split fresh from old.** Anything past a threshold (start: 24h) drops into a
  collapsed "Older" group. The default view shows what's live.
* **Detect moot.** The strong signal: the agent asked, got no answer, and *kept
  going* — later turns completed, or the harness was recycled, or the
  workspace/agent is gone. Those are almost certainly dead. Mark them, offer
  "clear all moot", never auto-delete.

Do **not** auto-expire on a timer alone. Answering an orphaned card still works
today (`Questions.with_entry` rebuilds the broker entry, `deliver_late_answer`
enqueues the selections), and silently dropping a human's pending decision is
the same class of bug as swallowing a message.

### 3. Phone: swipe + ask-back

* **Swipe** between slides. The Reviewer is *already* one-decision-per-slide, so
  this is a gesture over an existing model, not a new one. Respect the existing
  rule from `ui-build`: snap must be **proximity, never mandatory** — a decision
  taller than the viewport has to stay freely scrollable or its buttons become
  unreachable.
### 4. A decision is a conversation, not a form — but only when it needs to be

**The executive model.** Think of what an executive does when handed a decision:
sometimes they just decide — it's obvious, one beat, done. Sometimes they want
to understand the options before choosing. Sometimes they reject the menu and
ask for better options. Sometimes they want to know more about the answer *after*
choosing. All four are normal; the interface has to make the first one free and
the others available.

So the conversation affordance **must not tax the easy case**. A cheap, obvious
decision stays exactly what it is today: read it, tap it, gone. Discussion is a
door you can open, never a step you walk through. If adding depth makes the
one-tap decision feel heavier, the feature is wrong.

**A decision is a SIDEBAR, not part of the stream.** This is the structural
point and it settles where the thread lives: talking about a decision is a
branch off the main conversation, not more trunk. Sidebar discussion must not
push the agent's actual work down the chat, and must not be replayed into the
main stream as if it were the task. The decision owns its thread; the stream
just shows that a decision happened and how it landed.

Three things a human wants that a radio group can't express:

* **Clarify** — "what does option 2 actually change?" The agent answers; the
  card stays pending; you decide better.
* **Push on the premise** — "none of these are right", "you're assuming X".
* **Reframe** — the answer isn't picking an option, it's rewriting the
  question. The agent re-asks with better options, and the card *replaces
  itself* rather than resolving.

That makes a decision a small thread with a **terminal state** (answered /
skipped / superseded), not a form with two exits. Two consequences worth naming
before anyone builds it:

* **Reframing supersedes.** The old card must retire visibly — it can't just
  vanish (a human may have been mid-thought on it) and it can't linger as a
  second live question. `superseded` is a new card status, and the replacement
  should point back at what it replaced.
* **The reply must land on the card.** If a clarification answer only appears in
  the main chat, we've rebuilt the swallowed-message bug in reverse: the human
  asks at the decision and the answer shows up somewhere else. The thread hangs
  off the decision.

This is also what makes the phone story cohere: swipe to move between decisions,
talk to the one in front of you, and it either resolves or becomes a better
question.

### 5. How the sidebar actually works: a decision agent

Spin up an agent **scoped to the decision**, let it hold the back-and-forth in
its own context, and when the decision lands, roll only the *outcome* back into
the main agent's context.

This isn't only elegant — it's the one shape that survives the constraints:

**Constraint A: context cost.** A ten-message negotiation about which option to
pick has exactly one durable output: the choice, and maybe why. If that whole
exchange lands in the main agent's window, you've spent the trunk's context on
deliberation that summarises to one line. The sidebar keeps the transcript out
and returns the conclusion.

**Constraint B: nothing can stay blocked that long.** A live `ask_user` parks
the agent's turn *inside the tool call*, and three separate clocks are running:

| Clock | Value | Source |
|---|---|---|
| ACP elicitation waiter | **~60s** | comment at `questions.ex:435` |
| `Questions.ask` timeout | **10 min** | `@timeout_ms` |
| Stream stall watchdog | **10 min** | `@stream_stall_ms` |

An executive taking twenty minutes to think — which is *normal and good* — blows
through all three. So the decision conversation **cannot** happen inside the
blocked tool call. The main agent must be released; the sidebar owns the
deliberation; the answer arrives later.

**The good news: half of this already exists.** Loopyard already handles "the
answer arrived long after the waiter died" — `Questions.with_entry` rebuilds the
broker entry from the card, and `deliver_late_answer` enqueues the selections to
the agent. Relevance is already card state, not waiter liveness. The decoupled
model is the direction the code has been drifting anyway.

**What rolls back** into the main context, and nothing more:

* the resolution (chosen option, typed answer, or a replacement question), and
* a one-line *why*, when the reasoning changes what the agent should do next.

Not the transcript. If the agent later needs the detail, it can pull it —
`recall_conversation` already exists for exactly this shape of "read your own
history on demand."

**The leftovers problem — and why "fork vs. merge" is the wrong frame.**
A sidebar often produces something valuable that *isn't* the decision: "by the
way, we're deprecating that Rails app in Q3." Summarise-and-discard loses it;
merging the whole transcript defeats the point. But that dilemma only exists if
context is the only place knowledge can live — and here it isn't:

* **Nothing is discarded, because the sidebar is durable and addressable.** The
  thread persists on the decision. The main agent doesn't need it *pushed* into
  context; it can pull it the same way it already reads its own history
  (`recall_conversation`). "Not in context" ≠ "lost."
* **Genuinely durable facts belong in memory, not context.** "We're deprecating
  the Rails app in Q3" isn't a fact for *one agent's current window* — it's a
  fact about the project, and it should outlive this agent, this turn, and the
  next harness recycle. That's a `.claude/` memory or skill write, which agents
  here already do. Promoting it into one context window is the weaker move: it
  dies at the next recycle and no other workspace ever sees it.

So the resolution isn't "how much do we merge back" but **three targets**:

| What came out of the sidebar | Goes to |
|---|---|
| The decision itself (+ one-line why) | Main agent context — it changes the next action |
| Incidental but durable project fact | Project memory / skill — outlives every agent |
| Everything else | Stays on the thread, retrievable, pushed nowhere |

**Who decides which?** Start with the human — an explicit "keep this" on a
sidebar message is cheap, precise, and honest. Letting the sidebar agent guess
what's "interesting" is the same shape as the fabricated cost figure: a
confident classification nobody asked for. Auto-promotion is a later
optimisation, if ever, and should propose rather than write.

**Open engineering questions for this piece:**

* **What context does the sidebar agent get?** Enough to answer "what does
  option 2 change?" honestly — which is more than the card and less than the
  whole history. Probably: the question, the options, and read access to the
  main agent's recent turns via `recall_conversation` rather than a copy.
* **Reframe returns a question, not an answer.** The sidebar's output is
  sometimes a *replacement card* (see `superseded`), which the main agent must
  accept as its new ask rather than as its answer.
* **Cost.** A sub-agent per decision is not free. Cheap decisions must never
  spawn one — it starts only when a human opens the door (Section 4).
* **Who is the sidebar agent?** The operator is the natural candidate (it
  already embeds sub-agents and holds cross-workspace context), versus a
  purpose-spawned short-lived agent that dies with the decision.

### 6. The operator is the chief of staff — fewer, better questions

An executive isn't just given depth on each decision; they're given **fewer
decisions**. That's the operator's existing job (`CLAUDE.md`: "a chief of staff
— it reads status, dispatches work, and pulls detail on demand"), and it's the
half of the overwhelm problem that no amount of UI fixes.

Two jobs, in order of value:

* **Triage before it reaches you.** Not every agent question needs a human. Some
  are answerable from context the operator already has, some are duplicates
  across workspaces, some are moot by the time you look (see Decay). The
  operator should be able to answer, merge, or hold — and escalate only what
  genuinely needs a person. That is the difference between nine cards and two.
* **Question quality improves over time.** How a decision *resolves* is a signal
  about whether it was worth asking:
  - always answered with the recommended option → the agent should have decided
    it and told you
  - frequently **reframed** → the framing is bad; the options weren't the real
    choice
  - frequently **skipped** or left to rot → it shouldn't have been a question
  - answered fast, first time → good question, more like this

  None of that requires ML — it's counting outcomes per question shape and
  feeding it back into the agent prompt. The point is that the system gets
  quieter and sharper with use instead of accumulating.

**Careful:** an operator that silently answers on your behalf is the same
category of surprise as a message being swallowed. Anything it answers for you
must be visible after the fact and reversible, and "held" is not "hidden."

## Open questions

1. **Does the rail keep any list at all**, or just a count? A count is calmer;
   a short list is faster when there are two or three.
2. **What is "moot" exactly** — agent gone, workspace gone, N later turns
   completed, or a harness recycle? Each is detectable; they don't all mean the
   same thing.
3. ~~Thread placement.~~ **Settled: the sidebar model.** Decision discussion is
   a branch, not trunk — it lives on the decision, and the stream shows only
   that a decision happened and how it landed. Remaining sub-question: what do
   *other viewers* see while someone is mid-sidebar? Silence is calm but hides
   an in-flight negotiation from the team.
4. **Who can reframe?** A reframe rewrites the agent's question. If two people
   are watching the same decision, one reframing it out from under the other is
   the same class of surprise as the queue reordering itself.
5. **Does answering from the Reviewer still need the chat card to update?** It
   does today via the shared `ApprovalActions` path — keep that seam.

## Sequencing

Hierarchy (cheap, immediate relief) → age + Older split → swipe → moot
detection → conversational decisions (clarify, then reframe).

The conversation work is last on purpose: it's the only part that changes what a
decision *is*, and it needs the `superseded` status and the threading decision
settled first. Clarify ships before reframe — clarify leaves the card alone,
reframe replaces it.

## Sep 1 — Brad's read from the phone (settles the open questions)

Looked at live, on a 402px phone, with 14 decisions waiting — every one of
them between 21 and 23 days old, 12 of them asked by the operator itself.
What he said, translated into decisions for this plan:

**1. They are decisions, not questions.** The vocabulary changes everywhere a
human reads it: the Reviewer's eyebrow says DECISIONS, not REVIEW; the
operator tab already does. `:question` stays the card role in code.

**2. The mobile rail dies. The Decisions tab IS the deck.** On a phone the
"Decisions 11" tab renders the desktop rail: text rows that don't look like
the thing they point at. That list has no job a phone can use — tap a row and
you're in the Reviewer anyway. So on a phone the tab opens the deck directly
(the Reviewer, one decision per screen, swipe between them). Desktop keeps a
rail, but as a **count + at most three miniature cards** in the flame
language, tap → deck. Settles open question 1: a signal, not a second list.

**3. The decision screen strips to what a decision needs.** Today above the
question: `REVIEW · 14 waiting · history · mode-nav`, then `Operator`, then
`Asked 22d ago`, then a DECISION eyebrow, then a section header, then the
prompt. Six lines before the content. New anatomy, top to bottom:

```
‹  Decisions · 3 of 14                         ⌂
Operator · 22d ago                    ← ONE line: who asked, how long ago
<the prompt>                          ← text-lead, dominates
○ option — label / muted description  ← hierarchy per §1
[ Answer ]                            ← pinned, always reachable
```

Repo / workspace names appear only when the source is a workspace agent
(then `gbrain · main · Claude · 22d ago`), never as separate eyebrow + meta
+ subject lines. History and mode-nav move behind the back button's
neighbour, not the title zone.

**4. Age is first-class; newest first; the chief of staff sweeps.** §2 stands
and gets two additions. The deck orders **newest first** — recency is the
right bias here; a three-week-old ask is almost never the one to answer
next. And the operator, as chief of staff, runs the moot sweep §2 describes:
a decision whose source agent has completed later turns, been recycled, or
whose workspace is gone gets proposed as moot — "these 9 look dead, clear
them?" — one tap, visible, reversible. Never a timer alone.

**5. Chat with the decision — settled: a dedicated, disposable decision
agent.** Brad's question was whether a side chat would need to understand
the operator chat and the project it came from. The answer:

- **The context that matters is the SOURCE agent's, not the operator's.** A
  decision is a message in some agent's conversation; what "led up to it" is
  that agent's last turns. So the side agent is seeded exactly the way a
  resumed harness is (`ResumeMessage`-style): the card, the source agent's
  last N turns around the ask verbatim, and one identity line (project ·
  workspace · agent · asked when). For the 12 decisions the operator asked,
  the source IS the operator, so the seed is the operator's own recent turns
  — it sees the operator chat only because that's where the decision came
  from.
- **Who runs it: neither the operator nor the source agent.** Not the
  operator — its single chat and its context window are the precious thing,
  and a per-decision thread interleaved into it is the mess we're fixing. Not
  the source agent — it is parked inside the `ask_user` tool call with three
  clocks running (§5, Constraint B), and its context is what we're
  protecting. So: a **workspace-less `ChatAgent` in the workstation
  container, the same mechanics as the operator**, spawned only when a human
  taps "Discuss", idle-reaped like any agent, disposable.
- **Tools: read, plus one write.** `recall_conversation` scoped to the source
  agent (pull more history than the seed), `peek_workspace` / `overview`,
  read-only file access on the source workspace's volume — and
  `answer_decision`, which resolves the card through the same
  `Questions` / `ApprovalActions` path the buttons use, so
  `deliver_late_answer` works and the chat card updates. Nothing else writes.
  Reframe (`superseded`) comes later and is the second write.
- **The thread is durable and keyed to the decision** (`{agent_id, msg_id}`):
  reopen the decision, the thread is there. It is visible to every viewer —
  multiplayer by design — which settles the sub-question in open question 3:
  show the in-flight negotiation, don't hide it.
- **What rolls back to the source agent:** the answer, optionally with a
  one-line why appended. Never the transcript (§5 already argues this).

**6. Screen anatomy with the thread.** Card on top, thread below, composer
"Ask about this decision…" at the bottom, Answer pinned in a sticky action
bar so a long thread never buries the decision itself. On a phone, swipe
moves between decisions; the thread belongs to the one in front of you.
Opening the thread must cost nothing on the cheap case (§4): no agent is
spawned until the first message is sent.

### Revised sequencing

1. **Strip + rename + age-first** — the decision screen anatomy in (3), the
   DECISIONS vocabulary, newest-first ordering, and the mobile Decisions tab
   becoming the deck. Mostly deletion. One PR. This is the "fucking mess"
   fix and ships first.
2. **Moot sweep by the operator** — (4). Needs the moot detector from §2.
3. **Decision agent, clarify only** — (5) and (6). Seed + read tools +
   `answer_decision`. No reframe yet.
4. **Reframe / `superseded`** — the second write.
5. **Swipe** — the gesture over the existing one-per-screen model.
