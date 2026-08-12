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
