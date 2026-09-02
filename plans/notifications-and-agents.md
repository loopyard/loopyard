# Notifications + Agents

Epic: [#111](https://github.com/loopyard/loopyard/issues/111) (sub-issues
#101–#110, #112–#115). Grew out of [plans/decisions.md](decisions.md) (Sep 2
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
6. (#115) Aural: the bed's level from fleet busyness in `ActivitySound`;
   chimes fire off `Events.Notifications.Added` by kind (both chimes exist).

**Track B — Agents**
0. (#112) `Agent.Profile`: what an agent is, as data; one spawn path.
1. (#106) Global agents: generalise `Loopyard.Operator` to N; migration of
   `operator.json`; the operator = the first global agent.
2. (#110) Retire the operator's desktop rail — moved up: `OperatorLive` is
   741 lines against the enforced 800 cap, and this is what makes room.
3. (#107) `/agents/:id` pages (`AgentLive` from `OperatorLive`), `/operator` →
   the first, new-agent creation. Multiplayer verified with two viewers.
4. (#113) `/agents` — the Agents panel: every agent, flat, by scope, live
   status; launch global agents here (workspace agents launch in their
   workspace). The three icons in the existing top bar become the tab bar.
5. (#108) Notification tools + wake-on-item — **opt-in, last, droppable**;
   needs the machine-message channel first (review §3).

**Track C — the desktop shape of Notifications**
- (#109) Master-detail on a wide screen (list left, the chosen item + its
  thread right; click, not swipe). The phone keeps the deck.

## Not in scope here

- Login / privacy (the one front-door plug, tracked separately). Chats are
  multiplayer by default; "private" comes with identity.
- Renaming "operator" in modules. It becomes the first global agent and keeps
  its name until login gives it the person's.
- Project-scoped agents as a tier (a watch set covers it; the URL space leaves
  room for `/projects/:p/agents/:id` if a real need shows up).

## Architecture review (Sep 2) — does this fit the code we have?

Four read-throughs of the seams this touches (notifications, agent spawn,
aural, UI/nav). Verdict: **the model fits, and most of it is consuming
things that already exist** — but three parts of the plan were under-specified
in ways that would have bitten, and the review changes their issues.

### 1. Notifications — a store is the right call; three facts sharpen it

**Today the same number is computed three ways.** `Attention.line/0` is a
derived query: it unions the three broker ETS tables with a scan of EVERY
agent's summary (`:ets.tab2list(:chat_agents)` copies every message list out
of ETS), then a `WorkspaceTree.global/1`. It runs on the dashboard's 3 s tick,
the operator rail refresh, `recent_activity`, AND inside every web-push
payload (`WebPush.waiting_count/0`). Three surfaces sort it three ways (oldest
first, newest first, first-four-of-oldest). A store with maintained counts
removes all of that; it is not an abstraction for its own sake.

**"An agent finished" is not a durable fact anywhere.** The turn-end signal
is `Events.Activity.Event{kind: :status, summary: "idle"}` — the string
"idle", nothing more. The human-readable summary is reconstructed after the
fact by `Operator.Digest.last_said/1`: a blocking `ChatAgent.get_state/1`
plus regex markdown surgery. The digest ring itself is 100 entries in ETS
with a `seq` that resets to 0 on GenServer restart (ordering corrupts).
→ **#102 must publish the summary at turn end** (StreamHandler, where the
final assistant message is in hand), not read it back.

**Durability has a hole the store must not inherit.** A card answered while
its agent's GenServer is down is patched in ETS and never written to the
agent log (`MessageWindow.update_message_now/3`). And
`Persistence.state_log_path/1` returns `nil` for anything that is neither a
workspace agent nor the operator. → **#101 gets its own log + writer**
(mirroring `AgentLog`'s record/replay shape), not a ride on the agent's.

**There is no retract primitive, but there is a cheap one.**
`Questions.cancel_for_agent/1` kills waiter tasks and stamps `:timeout`; it
fires only when the agent is already idle. The ACP elicitation path already
answers a timed-out ask with `decline` and the turn continues — so
**retract = answer the ask with `decline` + a reason on the card**, through
the broker's existing reply path. No kill. (#103)

### 2. Agents — the Profile is right, and the spawn seam is the real work

The two spawn paths differ in **far more than opts**:

| | workspace agent | operator |
|---|---|---|
| supervisor | `WorkspaceGroup` → `RestartController` (crash history, quarantine, boot accounting) | bare `DynamicSupervisor.start_child(AgentSupervisor)` — no restart policy at all |
| boot | `AgentBoot` saga, `:booting` ETS stub, 120 s deadline, boot-failed UI | synchronous `{:ok, _} =` bang-match; never shows as booting |
| log | `<ws>/.loopyard/workspace/agents.log` via a `Checkpointer` (compaction, single writer) | `<workstation>/operator-agent.log`, direct append, never compacted |
| boot restore | `restore_all_agents` walks the workspace registry | nothing — exists only if something calls `ensure_agent` |
| read side | `WorkspaceTree.global/1` | the `nil` bucket is computed and DROPPED; `OperatorLive` and `Attention.path/3` hand-patch it |

And the discriminator is a **shape, not a field**: `Initializer.build_session_opts`
decides five things (brief target volume, MCP scope, container, cwd, whether
`:volume` is set) with one `cond` over `(container_only?, is_binary(workspace_id),
is_binary(opts[:container]))`. `summary/1` has 38 keys and none of them is
scope; everything downstream re-derives "is this the operator" from
`(workspace_id, container)` in at least four places. `Onboarding.spawn_agent/2`
forwards exactly `[:tools, :system_prompt, :host_access]` and drops
`:harness/:model/:container/:initial_messages/:claude_session_id` (it reads
`:backend` for the NAME and then discards it — a live bug).

So **N global agents on today's operator path would share one uncompacted
log, have no restart policy, never appear as booting, and be invisible to
the tree.** #112 is therefore not "add a struct": it is

1. `Agent.Profile` as data, AND `summary/1` gains `scope` + `tools` so the four
   derivation sites collapse to one field.
2. ONE supervisor shape: global agents get the same `RestartController` +
   `Checkpointer` machinery, keyed by a scope key (`workspace_id` today, the
   agent id for a global one). No second-class agents.
3. ONE boot path (`AgentBoot` saga) for both.
4. Per-agent global log `<workstation>/agents/<id>.log` with a Checkpointer;
   a `Loopyard.Agents` registry that boot restore walks.
5. `WorkspaceTree.global/1` (or a sibling read) renders the Loopyard-scoped
   bucket instead of dropping it.
6. `Onboarding.spawn_agent/2` forwards the `@rebuildable_opt_keys` set.
7. `ToolRouter.tool_modules/1`'s catch-all must ERROR on an unknown scope
   (today an unrecognised scope silently gets the workspace toolkit). Two MCP
   scopes stay: global agents keep the `:operator` scope (rename later).
8. The brief composes: ~70 % of `Operator.prompt/1` (13.2 k chars) is
   phone-screen comms style shared by any global agent; only the tool
   sections are the operator's. Shared style block + per-profile capability
   block, or N copies drift.

### 3. Agents reacting to notifications — the missing channel

Confirmed: there is **no machine-authored message into an agent**.
`enqueue_message/2` renders as a human `role: :user` message and is framed
*"You sent N messages while I was working"* — it would lie about authorship.
`{:resume_prompt, text}` (what `notify_when_done` wakes use) is silent,
non-durable, and **dropped if the agent isn't idle** (never queued, by
design). `Digest.watch/4` is one watch per agent, last-arm-wins, in GenServer
memory, lost on crash. So #108's real design work is a **third channel**:
durable, queued in `pending_sends` alongside human sends, framed as system
in the batch prompt, rendered as a band (not a user bubble). That is what
"turn-taking" means here, and it stays opt-in and last.

### 4. UI/nav — consistent, with two things to reckon with

The three-tab bar **reverses** `plans/ia-two-modes.md`'s Aug 1 argument
("the Operator is ABOVE the workspaces; the control never represents where
you are"). That is consistent, not a flip-flop: the altitude argument was
about the operator being a singleton above everything, and that premise is
gone once it is one row in Agents. The original plan also argued FOR a tab
bar ("deliberately shaped like an iOS tab bar… keep the modes URL-rooted").

Two things the plan had not reckoned with:
- **Per-tab memory was never built.** "Each mode remembers where you were"
  is in the Aug 1 doc; the grid link and the phone back button are hardcoded
  `/workspaces`. A tab bar makes that expected. (#113 gains it.)
- **`/` is where first-run onboarding, System and Connections live.** It
  stays the home behind the brand mark; nothing on the tab bar replaces it.

Constraints the guardrail test enforces on a new bar: the design-system test
fails any `h-14 … border-b` bar not routed through `.app-bar` (sticky TOP),
and `safe-area-top` is allow-listed per page shell with no bottom slot. The
workspace chat already spends two bars (~120 px) on chrome. → **The tab bar
is the existing top bar's right zone: three icons with an active state.** No
bottom bar, no third chrome surface on the phone. A bottom bar is the native
wrapper's, later.

Concrete facts that fold into issues: the push URL is still
`/operator/decisions/…` and `sw.js` falls back to `/review`; the PWA badge
only refreshes while `/operator` is open and the service worker computes a
DIFFERENT count; the PushBell toggle exists only in the `hidden lg:flex`
desktop rail, so **a phone cannot subscribe to push today**. (#114, #105.)
`AgentLive` has 59 lines of headroom under the 800-line cap, so #110 (retire
the rail) moves BEFORE #107.

### 5. The aural stream — what drives it, and the chimes already exist

**The bed's loudness is driven by exactly one thing: the operator's own
status, from `OperatorLive.drive_sound/1`** — 0.7 while `:thinking`, 0.12
otherwise — and only while someone has `/operator` open. There is no "how
busy is the machine" derivation; `Attention`/`WorkspaceTree` know the fleet
but are not wired to `set_activity`. The "bus" is `Events.Activity`
(global), which is exactly the right source; it is just not the source
today.

**Both chimes Brad asked for already exist and already fire.**
`LoopyardWeb.ActivitySound` subscribes to `Events.Activity` and mixes
server-side: `"done"` (C-E-G bell) when ANY agent goes idle, `"attention"`
(bowed A4) on `awaiting`, `"alert"` (dissonant dyad) on rate-limit / auth /
crash. `Aural.Signals` is the voice; chimes mix into the bed PCM before the
encoder. Gaps: only questions record `awaiting` (approvals and secrets are
silent); the `music` tool has no `fire` action; everyone on the channel
hears every chime 1–3 s late and hears nothing unless the bed is playing.
`sound_boundary_test` allows exactly two core files to touch `Aural`
(`events/aural.ex`, `tools/control_plane/music.ex`) — `ActivitySound` is the
bridge, and it must stay the only one.

→ New issue: **drive the bed from fleet busyness in `ActivitySound`** (a
server process, page-independent — e.g. fraction of agents thinking), and
**fire chimes off `Events.Notifications.Added` by kind** once the store
exists (finished → `done`, decision → `attention`, alert unchanged), so a
secret request rings like a question does. ~20 lines, no client change.

### Is it conceptually right for a human?

Three questions a person walks in with, three roots: *what's waiting on me*
→ Notifications; *who's doing what* → Agents; *the work itself* →
Workspaces. Home (`/`) is the front door with setup and System behind the
brand mark. Two honest costs: a workspace agent appears in two places (that
is fine — Agents is the directory, Workspaces are the rooms); and "ask
Loopyard what's going on" becomes Agents → the operator's row, two taps
where it was one. Mitigation without a fourth root: the dashboard keeps its
operator card, and the operator row pins to the top of Agents. The chimes
give the same model to the ear: a bell when work finishes, a tone when a
human is needed, a dissonance when something broke.
