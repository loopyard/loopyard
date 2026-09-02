# Notifications + Agents

Epic: [#111](https://github.com/loopyard/loopyard/issues/111) (sub-issues
#101–#110, #112–#114). Grew out of [plans/decisions.md](decisions.md) (Sep 2
sections), where Brad reframed the Operator/Decisions split.

## The model

Three roots, and only three: **Workspaces / Agents / Notifications**, with
the home dashboard behind the brand mark. An honest three-tab bar (the one
the native wrapper wanted); the "altitude" control's job ends once the
operator is one row in Agents.

1. **Workspaces** — agents (and people) minding their own business. Unchanged.
2. **Notifications** — one stream of "something needs a human, or happened":
   a decision to make (question / approval / secret), an agent that finished
   or went idle ("keep going?"). Durable, prioritised, each item carrying its
   actions. **Multiplayer**: the team's inbox, anyone acts. Decisions are one
   KIND of notification; today's Decisions deck is the whole thing until the
   other kind exists.
3. **Agents** — every agent, flat, whatever its scope. Brad: "you don't care
   about the dev servers. You're just like, oh look, there's a bunch of
   agents." One spot for the status of all of them; click in to follow along.

**An agent is ONE thing: a container + a brief + a tool scope.** That is
already true in the code, in two unnamed halves:

| | container | brief | tools (MCP scope) | spawn path |
|---|---|---|---|---|
| **workspace agent** | the work container on the code volume | `priv/agents/coding/agent.md` | `Tools.Container` (`:workspace`) | `Onboarding.spawn_agent/2` |
| **global agent** (the operator today) | the workstation container | `Operator.prompt/1` | `Tools.ControlPlane` (`:operator`) — awareness of every agent and workspace, the operation not the details | `Operator.spawn_operator/2` |

Formalising it = `Loopyard.Agent.Profile` (scope, container, brief, tools,
harness) + ONE spawn path (#112). A global agent's scope is Loopyard; there
is no third noun — the scope is the label ("Loopyard" where a workspace agent
shows "project · workspace"). The operator is the first global agent, not a
singleton; any number; each an ordinary multiplayer chat. "Private" is a
login-time attribute, not a chat type. Project-scoped agents are not a tier:
a global agent with a watch set of "every workspace in gbrain" is one.

The corner we were painting ourselves into: "one operator chat" as a fixed
part of the product. The reframe: notifications are the substrate, agents
(plural, one definition) act on the system, the operator is just agent #1.

## Do global agents react to notifications?

Brad isn't sure they should ("we could just skip doing that now"), so it is
**opt-in and last** (#108), and nothing else depends on it. The idea, so it
isn't lost: no blasting — the agent's durable inbox already does turn-taking.
A watched notification becomes a message in the agent's `pending_sends`
queue, delivered between turns, a burst framed as ONE batch (`send_batch`) —
this is exactly what `notify_when_done` does today for one workspace. The
chat would show each notification as a band on the stream, then the agent's
turn on it. And the tie-in with decisions: **humans decide, agents triage and
continue** — an agent never answers a decision; it may add context, retract a
moot one, reprioritise; on a finished item it does the "keep going".

## What exists that this builds on

| Piece | Today | Becomes |
|---|---|---|
| `Loopyard.Attention.line/0` | pending decision cards ∪ broker entries (durable, card-sourced) | the *decisions* subset of the notifications store |
| `Loopyard.Operator.Digest` | turn-end one-liners in a bounded ETS ring; the operator pulls via `recent_activity` | the *finished/idle* feed into the store |
| `Loopyard.Operator` + `Onboarding.spawn_agent` | two spawn paths, two prompts, two tool wirings | one `Agent.Profile`, one spawn path; `Loopyard.Agents` registry, N global agents |
| `Tools.ControlPlane` (`:operator` ACP scope) | overview / peek / dispatch / ports / create / notify_when_done | + notifications tools (list / act / retract / prioritise / watch) |
| `LoopyardWeb.OperatorLive` (`/operator`) | the operator's chat | `/agents/:id` — one page per global agent; `/operator` → the first |
| `ChatAgent.list_agent_summaries/0` / `WorkspaceTree` | the tree read | the flat read the Agents panel (`/agents`) needs |
| `LoopyardWeb.ReviewLive` (`/decisions`) | the deck, from `Attention.line` | `NotificationsLive` (`/notifications`): reads the store; both kinds render; desktop master-detail |
| `Loopyard.WebPush.notify_question` | push for questions (PWA), bell toggle in the rail | `notify/4` by kind; finished items too |
| `Events.Activity` (global) | fed by every agent's turn end | the source of finished/idle items |

## Sequencing

Three tracks; A before B's tools (they need something to act on), C
independent.

**Track A — Notifications**
0. (#114) Rename Decisions → Notifications: routes, crumb, copy; old links
   keep resolving. Cheap; first, so later work lands on the right word.
1. (#101) `Loopyard.Notifications`: one durable store (ETS via `StateKeeper` +
   ETF log), `Events.Notifications` publisher, item shape with kind / subject /
   summary / actions / status / raised_at / priority. `Attention.line/0`
   becomes a view over the decisions subset.
2. (#102) Finished / idle items from `Events.Activity`, debounced per agent,
   with actions (keep going → `dispatch`; open; dismiss).
3. (#103) Prioritisation: the ordering rule + retract / pin hooks (absorbs the
   `retract_decision` open call from plans/decisions.md).
4. (#104) `/notifications` reads the store: both kinds on the deck; badge +
   dashboard counts from it.
5. (#105) Push for finished items.

**Track B — Agents**
0. (#112) `Agent.Profile`: what an agent is, as data; one spawn path.
1. (#106) Global agents: generalise `Loopyard.Operator` to N; migration of
   `operator.json`; the operator = the first global agent.
2. (#107) `/agents/:id` pages (`AgentLive` from `OperatorLive`), `/operator` →
   the first, new-agent creation. Multiplayer verified with two viewers.
3. (#113) `/agents` — the Agents panel: every agent, flat, by scope, live
   status; launch global agents here (workspace agents launch in their
   workspace). The nav becomes the three-tab bar.
4. (#108) Notification tools + wake-on-item — **opt-in, last, droppable**.

**Track C — the desktop shape of Notifications**
- (#109) Master-detail on a wide screen (list left, the chosen item + its
  thread right; click, not swipe). The phone keeps the deck.

**Housekeeping**
- (#110) Retire the operator's desktop rail once A4 + B2 land (needs-you list
  duplicates `/notifications`; the push bell moves; the sound player is the
  pill).

## Not in scope here

- Login / privacy (the one front-door plug, tracked separately). Chats are
  multiplayer by default; "private" comes with identity.
- Renaming "operator" in modules. It becomes the first global agent and keeps
  its name until login gives it the person's.
- Project-scoped agents as a tier (a watch set covers it; the URL space leaves
  room for `/projects/:p/agents/:id` if a real need shows up).
