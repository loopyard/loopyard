# Notifications + staff agents

Epic: [#111](https://github.com/loopyard/loopyard/issues/111) (sub-issues #101–#110). Grew out of
[plans/decisions.md](decisions.md) (Sep 2 sections), where Brad reframed the
Operator/Decisions split.

## The model

Three things, and only three:

1. **Workspaces** — agents (and people) minding their own business. Unchanged.
2. **Notifications** — one stream of "something needs a human, or happened":
   a decision to make (question / approval / secret), an agent that finished
   or went idle ("keep going?"). Durable, prioritised, each item carrying its
   actions. **Multiplayer**: the team's inbox, anyone acts. Today this is the
   Decisions deck; the word stays "Decisions" until finished/idle items exist
   to earn the broader one.
3. **Staff agents** — agents you run *against* the notifications and the
   workspaces: workspace-less, control-plane toolset, watching workspaces and
   managing the workspace agents. The operator is the FIRST of these, not a
   singleton. Any number; each is an ordinary multiplayer agent chat (one
   person on several devices, or a few people reasoning together). "Private"
   is a login-time attribute, not a chat type.

The corner we were painting ourselves into: "one operator chat" as a fixed
part of the product. The reframe: notifications are the substrate, agents
(plural) act on them, the operator is just agent #1.

## What exists that this builds on

| Piece | Today | Becomes |
|---|---|---|
| `Loopyard.Attention.line/0` | pending decision cards ∪ broker entries (durable, card-sourced) | the *decisions* subset of the notifications store |
| `Loopyard.Operator.Digest` | turn-end one-liners in a bounded ETS ring; the operator pulls via `recent_activity` | the *finished/idle* feed into the store |
| `Loopyard.Operator` | one workspace-less ChatAgent per workstation identity (`operator.json`) | `Loopyard.Staff`: N such agents, the operator the default |
| `Tools.ControlPlane` (`:operator` ACP scope) | overview / peek / dispatch / ports / create / notify_when_done | + notifications tools (list / act / dismiss / prioritise / watch) |
| `LoopyardWeb.OperatorLive` (`/operator`) | the operator's chat | `/agents/:id` — one page per staff agent; `/operator` → the default |
| `LoopyardWeb.ReviewLive` (`/decisions`) | the deck, from `Attention.line` | reads the store; both kinds render; desktop master-detail |
| `Loopyard.WebPush.notify_question` | push for questions (PWA), bell toggle in the rail | `notify/3` by kind; finished items too |
| `Events.Activity` (global) | fed by every agent's turn end | the source of finished/idle items |

## Sequencing

Three tracks; A before B (staff agents need something to act on), C
independent.

**Track A — the notifications store**
1. (#101) `Loopyard.Notifications`: one durable store (ETS via `StateKeeper` + ETF
   log), `Events.Notifications` publisher, item shape with kind / subject /
   summary / actions / status / raised_at / priority. `Attention.line/0`
   becomes a view over the decisions subset.
2. (#102) Finished / idle items from `Events.Activity`, debounced per agent, with
   actions (keep going → `dispatch`; open; dismiss).
3. (#103) Prioritisation: the ordering rule + the agent-facing reprioritise/retract
   hook (absorbs the `retract_decision` open call from plans/decisions.md).
4. (#104) `/decisions` reads the store: both kinds on the deck; badge + dashboard
   counts from it.
5. (#105) Push for finished items.

**Track B — staff agents**
6. (#106) `Loopyard.Staff`: generalise `Loopyard.Operator` to N agents; migration of
   `operator.json`; the operator = the default staff agent.
7. (#107) `/agents/:id` pages (StaffLive from OperatorLive), `/operator` → default,
   new-agent creation, mode nav "up" → default + a switcher. Multiplayer
   verified with two viewers.
8. (#108) Notifications tools in `Tools.ControlPlane`; watch sets; wake-on-item
   (rate-limited, config-gated) replacing the digest pull.

**Track C — the desktop shape of Decisions**
9. (#109) Master-detail on a wide screen (list left, the chosen decision + its
   thread right; click, not swipe). The phone keeps the deck.

**Housekeeping**
10. (#110) Retire the operator's desktop rail once 4 + 7 land (needs-you list
    duplicates `/decisions`; the push bell moves; the sound player is the pill).

## Not in scope here

- Login / privacy (the one front-door plug, tracked separately). Staff chats
  are multiplayer by default; "private" comes with identity.
- Renaming "operator" in routes/modules. `Staff` is the new module; the
  operator keeps its name as the default staff agent until login gives it
  the person's.
