> Archived Sept 2026 — superseded by plans/decisions.md and plans/notifications-and-agents.md; the Reviewer became `LoopyardWeb.NotificationsLive` (`/notifications`, with `/review*` kept as an alias).

# Questions: a design language + the Review flow

## The insight (Brad, Jul 26)

Questions deserve to be a first-class, *recognizable* thing — and answering
them is a FLOW, not a page visit:

1. **Design language** — one visual identity for "a question" everywhere: the
   flame band (StreamCard :needs_you) at full size; a *miniature* of the same
   language in compact rows (flame left edge + wash + the question's own words,
   not a generic label). People learn the shape.
2. **Rail: nested under the repo** — workspaces with pending questions stick to
   the top of the list, their questions nested beneath (gist visible). Tap →
   review.
3. **The Reviewer (`/review`)** — a dedicated answer-many-back-to-back surface:
   ONE question per screen, prev/next, position indicator, answer → advance to
   the next pending item. Live: leave it open and new questions appear in the
   queue. Tearable into its own tab; looks right on mobile and desktop. The
   permalink (`/messages/...`) stays for SHARING one thing; the Reviewer is for
   WORKING the line.

## Mechanics

- Source: `Attention.line/0` (durable, card-sourced — never loses an item).
- Current item keyed by `{agent_id, msg_id}` so queue churn doesn't jump you.
- Cards render live from the message store (same interactive cards as chat:
  ConsentUI + queued/blocking approval decide via shared ApprovalActions).
- On resolve: brief settled beat, then auto-advance to the next pending.
- Empty state: "Nothing waiting on you." — calm, not celebratory.
- Entry points: operator rail rows, "For you" links, dashboard Operator panel.
