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
### 4. A decision is a conversation, not a form

The biggest idea here, and the one that reframes the rest: **you should be able
to talk to a decision.** Three things a human wants that a radio group can't
express:

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

## Open questions

1. **Does the rail keep any list at all**, or just a count? A count is calmer;
   a short list is faster when there are two or three.
2. **What is "moot" exactly** — agent gone, workspace gone, N later turns
   completed, or a harness recycle? Each is detectable; they don't all mean the
   same thing.
3. **Thread placement.** The clarification exchange hangs off the decision — but
   does it *also* echo into the main chat? Both places risks the swallowed-
   message bug in reverse; neither risks a conversation the rest of the team
   can't see. This is a multiplayer question, not just a layout one.
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
