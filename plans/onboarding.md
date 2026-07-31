# Onboarding — first run to first shipped change

Tracking issue: [#72](https://github.com/loopyard/loopyard/issues/72)

The goal: a developer who has never seen Loopyard gets from `mix loopyard.server`
to a working project + agent without guessing. We find the gaps by *being* that
developer, repeatedly, and screenshotting every step.

## Method

One loop, run until boring:

1. Bring the system to the state a new user would be in.
2. Look at the screen and ask: **"What do I do next?"**
3. Screenshot it.
4. If the answer isn't obvious FROM THE SCREEN, that's a finding — record it
   here, file a sub-issue under #72.
5. Fix, re-run, screenshot again.

Rules that keep this honest:
- The terminal is not part of the UI. If the only way to know something is to
  read server logs, the UI has failed.
- "New user" means no Claude token, no GitHub token, no projects, no images.
  Resetting to that state is part of the loop.
- Don't quietly fix friction found mid-run — capture it first, or we lose the
  evidence of what a new person actually hits.

## The intended path

What a new developer actually has to do, in order. This is the scope — we stop
at a running dev server.

1. **Install + boot** — `mix loopyard.setup`, `mix loopyard.server`.
2. **Docker must be reachable** — the substrate. Covered by #72's first
   sub-issues.
3. **"This is a new operator"** — the first screen should recognize a fresh
   install and say so, rather than showing an empty dashboard.
4. **Get inference working** — Claude auth. NOTHING else works before this: the
   agent is what builds everything downstream.
5. **Agent-guided from here.** Once inference is live, an agent walks the user
   through the rest — this is the pivot point of the whole flow. Onboarding
   stops being static UI and becomes a conversation.
6. **Set up the workstation** — GitHub CLI + token first (the happy path), then
   whatever else the developer uses (fly, etc.).
7. **Pull in a project** — GitHub is the happy path.
8. **Fire up the workspace** — agent writes Dockerfile/compose, boots the
   cluster. Run this several times across different stacks to prove the
   compose-cluster agent actually works.
9. **Show them the dev server** — where it is, how to reach it, and how to get
   the agent into it. This is the payoff screen; the flow is not done until the
   user is looking at their own app running.

Each step should end with the UI telling you what step N+1 is.

## Findings

### Iteration 1 — fresh boot, empty everything (2026-07-30)

State: empty `~/.loopyard`, no images, no containers, no Claude token.
Screenshot: `01-fresh-boot.png`.

The dashboard shows three cards: Workspaces (`0 projects · 0 workspaces ·
0 agents`), Operator (`Running the shop as brad` / `Chat with the operator` /
`For you` / `Workstations · 1`), System (`healthy`).

**F1 — No call to action anywhere.** The Workspaces card reports emptiness but
offers no way to resolve it. There is no "Add project" button on the page.

**F2 — The only way in is a terminal URL.** Adding a project requires
`/launch/<secret>?path=…`, printed to stdout at boot and absent from the UI.
Close the terminal and a new user is stuck with no path forward.

**F3 — "All 3 subsystems healthy" is misleading.** There is no Claude token, so
no agent can run — the product cannot do its central job while the dashboard
reports everything is fine. Health measures SUBSYSTEMS; a new user needs
READINESS. "Can I actually do the thing?" is a different question from "are my
GenServers up?"

**F4 — Inference is invisible.** Claude auth — the true first step — has no
presence on the first screen. Nothing prompts it, nothing reports its absence.

**F5 — Workstation/operator are unexplained.** `Workstations · 1` exists
already, with no indication of what it is, that it needs tokens, or that it's
where GitHub/fly credentials will live.

### Iteration 2 — walking it as the developer (2026-07-30)

Screenshots: `02-workspaces.png`, `03-new-project.png`.

**Correction to F1:** the CTA does exist — just not where a new user lands.
`/workspaces` has a "+ New project" button. The dashboard is a dead end that
hides the action one click away.

**F6 — "From GitHub" is `SOON`.** `/projects/new` offers From scratch / From a
folder on this machine / **From GitHub (SOON)**. The intended happy path — the
one the whole workstation + `GITHUB_TOKEN` setup exists to serve — is not
implemented. Everything upstream of it (install `gh`, transfer the token) leads
to a door that doesn't open yet. This is the single biggest gap in the flow.

**F7 — "From a folder on this machine" is ambiguous, and wrong when remote.**
Loopyard may run on a different box than the developer's Mac (the case the
`curl | sh` push exists for). "This machine" then means the SERVER's disk,
which the developer may have no access to. The copy silently assumes
server == laptop.

**F8 — Nothing gates on inference.** A new user can walk dashboard →
workspaces → new project → create, never once being told Claude auth is
required. The failure surfaces later as `Claude auth failed: Authentication
required` in the EventLog — observed for real on this machine earlier today,
which is exactly how a first-timer would experience it.

**F9 — copy nit:** "Nothing here yet — create your first project below." The
button is above-right; what's below is "No projects yet."

### README drift (2026-07-30)

`README.md` documents `mix deps.get` → `mix loopyard.setup` →
`mix loopyard.server` → launch URL, and:

- **Never mentions Docker** must be installed and running, though it is the
  substrate for everything.
- **Never mentions Claude auth**, while promising "clone a repo, launch it, the
  setup agent figures out the rest" — impossible without inference.
- **Never mentions GitHub tokens** or the workstation.
- **Still describes a "setup agent"** ("Setup agent auto-detects the stack"),
  a concept `CLAUDE.md` explicitly retired: "There is no separate 'setup
  agent.'" One self-determining agent now.

## Secret injection is ALREADY soft-coded — the gap is discovery

Worth correcting up front, because it changes what to build: credential
transfer is *not* hardcoded per-secret. `Loopyard.Workstation.Integration` is a
registry of tools — today **github, claude, codex, fly** — where each entry
declares an id, label, console hint, and a keychain-aware `mac_script/4`.
Adding a tool a different developer needs is a registry entry, not new plumbing.

The transport already exists too (`LoopyardWeb.SetupController`, gated by
`PushAuth`):

```
/workstations/:id/setup.sh          # every tool, one curl
/workstations/:id/:tool/setup.sh    # a single tool
/workstations/:id/env/:KEY          # gh auth token | curl -T - …/env/GITHUB_TOKEN
/workstations/:id/file/<path>       # curl -T - …/file/.codex/auth.json
```

**KEEP THIS.** It handles things that are easy to underestimate: macOS keeps
`gh` and Claude credentials in the Keychain (so `cat ~/.claude/.credentials.json`
transfers nothing), and Claude's durable path (`claude setup-token`, 1-year
token) is interactive — under `curl | sh` its prompts are both hidden and
starved of stdin, which the script solves by feeding it `/dev/tty` and teeing
output back while capturing the token by pattern.

So the real gaps are:

- **Discovery.** Nothing on first run tells a user this exists. The whole
  mechanism is invisible unless you already know the URL.
- **Ordering.** Claude must come first (it unlocks the agent that guides the
  rest), but the bulk `setup.sh` treats all tools as peers.
- **In-container initiation.** Today transfer is push-from-Mac. Brad's idea —
  something *inside* a container asking for a named secret — is the missing
  direction. `request_secret` / `get_secret` MCP tools and the `Loopyard.MCP`
  bridge are the pieces to build it from.

Open questions for the in-container direction:
- Who authorizes — human approval per secret, or per-tool policy?
- How does a tool DISCOVER what it needs (`gh` wants `GITHUB_TOKEN`) vs. being
  told?
- What does the UI show while a container blocks waiting on a secret?

See `docs/SECURITY.md` first — the container boundary is the security model,
and this is the one surface that crosses it.

### Three ways in — all three already exist

Don't over-index on any one of them. A developer arrives in different
situations, and the right answer differs:

1. **`curl | sh` from their Mac** (`SetupController`) — best when they have a
   terminal and an existing local login. Keychain-aware, handles Claude's
   interactive `setup-token`.
2. **Secret-through-chat** (`Tools.Container.RequestSecret`) — the agent asks,
   a masked field appears, the value never enters the transcript. Multiplayer-
   safe: other viewers see that a secret was added, not what it was. This is
   the LAST RESORT path and it's the one that saves you — on a phone, away from
   your desk, something broke and you have no terminal. Already wired into
   `Attention` as a `:secret` card, so it can't get lost.
3. **OAuth** — doesn't exist yet, and has a real structural problem below.

### OAuth is hard here because we're self-hosted

An OAuth provider needs a registered redirect URI. Loopyard is self-hosted, so
we do NOT control the URL a given install answers on — it could be
`localhost:4000`, a LAN IP, a tunnel, or a custom domain. There is no single
callback we can register up front.

This is worth designing deliberately rather than discovering late. Rough
options, none free:
- A Loopyard-operated broker with one fixed redirect URI that forwards the
  grant to the user's install (adds a hosted dependency to a self-hosted tool —
  philosophically expensive).
- Device-authorization flow, where supported, which needs no redirect at all
  and is phone-friendly. `gh auth login` already uses this — the existing
  GitHub integration proves the pattern works.
- Per-install app registration (the user creates their own OAuth app) — most
  sovereign, worst onboarding.

Device flow looks like the best fit for the ethos: no redirect, no broker,
works from a phone. Worth confirming which providers support it before
committing.

### The developer may be on a different machine

A constraint that shapes all of the above: the Loopyard server is not
necessarily on the developer's laptop. That is precisely why the transfer is
`curl | sh` run on THEIR Mac pushing credentials UP to the server, rather than
Loopyard reaching down into their filesystem. `PushAuth` already reflects this
(local needs no token; remote needs `?token=`).

Consequences to design for:
- Any copy saying "this machine" is ambiguous and probably wrong (see F7).
- Onboarding must be completable from a browser pointed at a remote Loopyard,
  with a terminal on the developer's own laptop — and nothing else.
- The launch URL trick (`?path=$(pwd)`) is inherently local-only; a remote user
  has no equivalent, which makes the missing GitHub path (F6) more load-bearing,
  not less.

## Open thread: an operator-brokered secret bridge (MCP)

The transfer scripts are currently hardcoded per tool (`Integration.mac_script/4`).
The idea worth exploring: instead of Loopyard shipping a script per tool, give
the OPERATOR agent an MCP tool that can open a one-time bridge — mint a
short-lived endpoint on the server, hand the developer a script to run on their
machine, and receive the secret back over it. The operator becomes the only
thing that can open that bridge, and new tools need no new Loopyard code.

Why it's appealing: it collapses "add support for tool X" from a code change to
a conversation. The agent already knows what a tool needs (it can read `gh`'s
docs); the missing piece is a sanctioned way to get a value from the human's
machine to the workstation.

Why it's hard, and worth being honest about:
- The MCP tool has to teach the operator what's ON the developer's machine and
  how each tool stores credentials — that's the knowledge currently encoded in
  the keychain-aware scripts. An agent guessing at this will get it wrong in
  ways that fail silently (see the `cat ~/.claude/.credentials.json` trap).
- An agent-generated script that runs on the developer's Mac is a serious trust
  boundary. Today the scripts are code-reviewed and served by us; then they'd
  be model output executed with the user's shell. That needs a review step, or
  a constrained template the agent fills rather than free-form script
  generation.
- Endpoint lifetime, scoping, and replay all need answering (`PushAuth` +
  `PushToken` are the starting point).

Verdict for now: promising, NOT the first move. The existing three paths cover
real situations today, and the immediate onboarding win is discovery/ordering.
Revisit once the happy path (F6) actually works end to end.

## UI rules for onboarding surfaces

Onboarding must be as good on a phone as on a large display. The workspace UI
is the reference for "dialed in"; the root homepage is the weakest page and is
where this work lands, so it needs the most care.

- **Mobile-first sizing, shrink at `md:`.** Tap targets need ~44px on a phone;
  desktop can tighten because a cursor is precise. `command_box` now does this
  (`py-3 md:py-2.5`, `text-sm md:text-xs`, button `self-stretch md:self-start`).
- **No tiny inline links as primary escapes.** Secondary routes get block
  layout with real vertical padding on mobile, collapsing to inline at `md:`.
- Follow the `ui-rhythm` skill for spacing/grouping before adding new layout.
- Reuse `LoopyardWeb.Components.*` (`command_box`, `status_pill`, `nav_row`,
  `section`) rather than inventing — the Workstation page already solved most
  of this vocabulary.

## Open thread: multi-environment tooling

Raised as important and not yet captured anywhere: agents need tools that can
see and act on environments BEYOND the dev container — production, staging.
Deploying to each, and especially READING from them, turns out to matter a lot
for debugging (the bug is usually only reproducible where the real data is).

Not in the onboarding scope above, but it lands on the same foundation: `fly`
is already an `Integration` entry, so the credential path exists. What's missing
is the tool surface for "look at staging" / "deploy production" as first-class
agent capabilities. Capture properly as its own issue before designing.
