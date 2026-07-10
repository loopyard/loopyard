# Cringe list — make Loopyard a joy to use

The loathsome-but-cheap papercuts. "What makes me cringe" = the backlog.
Add freely; fixing top-down. Status: 🔴 todo · 🟡 in progress · ✅ done.

## From the 2026-07-09 session (felt in real use)
- ✅ **Auto-start workspaces on boot** (#52) — a server restart leaves you on crashed agents in powered-down workspaces; you have to click Start. Restore the last working state.
- 🔴 **Self-restart footgun** — asking the in-Loopyard agent to "restart the Loopyard server" SIGTERMs its own host mid-task and takes itself out. Guard it (refuse/detach), or run the server under a keep-alive that respawns.
- 🔴 **Percolation black box** — long "Percolating…" shows no live signal; token counts freeze until turn end. Live output-token counter + a "current action" line.
- 🔴 **Model switching is code-only** — `agent_model` config exists now; add an in-UI model picker in the CLAUDE panel.
- 🔴 **"Harness offline" is ambiguous** — can't tell normal-restored from actually-broken. Clearer status + the why.
- 🔴 **Fable `thinking_tokens` events spam parse warnings** — SDK doesn't know them; teach it, get thinking-token accounting.

## BIG IDEA — the Foreman agent (control-plane concierge)
The dread of "all the clicking to get a project running" → a persistent
top-level agent that owns the CONTROL PLANE, not the code:
- Create projects/workspaces from natural language: "create a new project on
  github at bradgessler/blog" → it sets up GH + the workspace + container.
- Home for the user's push/pull tools + creds (the git ingress side).
- Tracks all projects/workspaces; answers "what was I working on?"
- Can QUERY the worker agents (read their status / ask them), but MUST NOT
  reach in and mutate their work. Read-only introspection first; "relay a
  question to a subagent" is a v2.
- Keep it simple: it's just another ChatAgent with control-plane tools + a
  query-only view into the others. Most primitives already exist (Onboarding,
  ProjectRegistry, agent summaries in ETS).

## UI / layout (the gold-standard 3-pane)
Vision: **left** = all projects + workspace hierarchy, navigable in the sidebar,
showing state of every workspace/project (replaces the top breadcrumb).
**middle** = agent chat. **right** = the CHANGES the agent made + key state
(status, model, cost); tools & deep detail behind a click, not always-on.
- 🔴 **Top breadcrumb sucks** (`Loopyard > Beautiful Ruby > main`) — redundant; move hierarchy into the left sidebar.
- 🔴 **Left sidebar only shows current project's workspaces** — should be the global nav tree (all projects → workspaces → agents) with live state dots.
- 🔴 **Right panel is overwhelming** — 8 stacked sections (Agents/Services/Volumes/Context/Info/Docker/Claude/Tools). The TOOLS wall especially. Triage: promote "Changes" to the hero, keep a compact status strip (model/status/cost), collapse the rest behind disclosures / a click.
- 🔴 **Right panel isn't the "changes" view** — the diff/files the agent touched live in the chat middle; the right should be the persistent "what did it change" surface.
