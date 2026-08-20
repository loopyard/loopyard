# Epic: Multi-agent harnesses — full-fidelity Claude, plus Codex and friends

Status: **analysis / proposal**. Nothing here is built. Derived from a read of
[pingdotgg/t3code](https://github.com/pingdotgg/t3code) (@ `main`, Aug 2026) against Loopyard as it
stands on `main`.

---

## 0. Why look at t3code

T3 Code calls itself an "agent harness control surface": a local server that owns agent sessions,
workspaces and version control, plus web/desktop/mobile clients over one authenticated RPC socket.
It ships **five** harnesses behind one contract — Claude, Codex, Cursor, Grok, OpenCode — and its
orchestration layer does not know which one is behind a thread.

That is the same shape as Loopyard's `Loopyard.Harness` behaviour, one generation further along. The
useful part is not their code (Effect-TS, event-sourced SQLite, no containers) — it's **what they
found they had to model** to make a harness feel first-class, and **which transport they picked per
vendor and why**.

Two findings drive this whole epic:

1. **They deliberately did NOT use ACP for the vendors that have a native protocol.** Claude runs on
   `@anthropic-ai/claude-agent-sdk`; Codex runs on the Codex **app-server** JSON-RPC protocol
   (`packages/effect-codex-app-server`). ACP is used only for Cursor and Grok — the two that offer
   nothing else. ACP is the fallback door, not the front door, because it drops most of what makes a
   harness legible.
2. **Their neutral event vocabulary is ~45 event types wide.** Loopyard's `Loopyard.Agent.Event`
   union is 12 structs, and the ACP translator only ever produces 8 of them. The gap between those
   two numbers *is* the "we don't have reasoning, etc." complaint.

---

## 1. How t3code integrates with Claude

### Transport

`ClaudeDriver` (`apps/server/src/provider/Drivers/ClaudeDriver.ts`) →
`ClaudeAdapter` (`Layers/ClaudeAdapter.ts`, **4,644 lines**, 4,613 lines of tests) wraps the Claude
Agent SDK's `query()` directly. Options wired from day one: `cwd`, `model`, `permissionMode`,
`maxThinkingTokens`, `resume` / `resumeSessionAt`, `includePartialMessages`, `canUseTool`, `hooks`,
`env`, `additionalDirectories`, `pathToClaudeCodeExecutable`.

Live session control (no restart): `interrupt()`, `stopTask(taskId)`, `setModel()`,
`setPermissionMode()`.

### Everything they pull out of the SDK stream

From grepping the adapter's message handling, these SDK frames are all mapped to canonical events:

| SDK surface | What it becomes |
|---|---|
| `content_block_delta` `text_delta` / `thinking_delta` | `content.delta` with `streamKind: assistant_text \| reasoning_text` |
| `thinking` blocks, `thinking_tokens` | `reasoning` **items** (persisted, not just streamed) |
| `tool_use` / `tool_result` / `input_json_delta` | `item.*` with a canonical `itemType` |
| `TodoWrite` input | `turn.plan.updated` (a real plan/todo surface) |
| `ExitPlanMode` | `turn.proposed.completed` + a plan-approval card |
| `task_started` / `task_progress` / `task_updated` / `task_notification` | `task.*` — the **subagent roster** |
| `parent_tool_use_id` on any frame | re-homes that item out of the main timeline into the owning subagent |
| `hook_started` / `hook_progress` / `hook_response` | `hook.*` |
| `tool_progress`, `tool_use_summary` | `tool.progress`, `tool.summary` (elapsed seconds, one-line summary) |
| `compact_boundary` (+ `compact_metadata` pre/post tokens) | `thread.state.changed → compacted` + usage snapshot |
| `result` message | `turn.completed` with `usage`, `modelUsage`, **`totalCostUsd`**, `stopReason` |
| `rate_limit_event` | `account.rate-limits.updated` |
| `auth_status` | `auth.status` |
| `commands_changed` | live slash-command list |
| `background_tasks_changed` | background task badge |
| `mcp_tool_use`, MCP status/oauth | `mcp.status.updated`, `mcp.oauth.completed` |
| `model_refusal_fallback` | `model.rerouted` (from→to→why) |
| `memory_recall`, `prompt_suggestion`, `plugin_install`, `files_persisted`, `image_view`, `web_search` | their own item/event types |
| `canUseTool` callback | `request.opened` → approval card → decision back through the callback |
| `canUseTool("AskUserQuestion")` | `user-input.requested` → the structured question card |
| `permission_denied` | `tool.denied` |

### Canonical vocabulary (`packages/contracts/src/providerRuntime.ts`)

Worth reading in full — it is the single best artifact in the repo. Highlights:

- `CanonicalItemType`: `user_message`, `assistant_message`, **`reasoning`**, **`plan`**,
  `command_execution`, `file_change`, `mcp_tool_call`, `dynamic_tool_call`,
  `collab_agent_tool_call`, `web_search`, `image_view`, `review_entered`/`review_exited`,
  `context_compaction`, `error`, `unknown`.
- `RuntimeContentStreamKind`: `assistant_text`, `reasoning_text`, `reasoning_summary_text`,
  `plan_text`, `command_output`, `file_change_output` — one stream channel per *meaning*, so
  reasoning is a first-class channel and not a display hack.
- `ThreadTokenUsageSnapshot`: used / total-processed / max / input / cached-input / output /
  reasoning-output, plus per-turn `last*` deltas, `toolUses`, `durationMs`, `compactsAutomatically`.
- `TaskAgentLinkage` (repeated on **every** task row, not just start): `taskType`, `agentKind`,
  `agentId`, `parentAgentId`, `title`, `role`, `model`, `effort`, `workflowName`, `phaseIndex`,
  `runHandles`… The comment explains why: so a client fold can reconstruct an agent even when its
  start row aged out of retention.
- `classifyTaskAgentKind` is a **denylist**, with a comment about why an allowlist silently dropped
  real subagents when the SDK renamed `subagent` → `local_agent`. Harness vocabularies drift; plan
  for it.
- Every event carries `raw: {source, method, messageType, payload}` — provenance is preserved so a
  debugging surface can show the untranslated frame.

### Around the harness

- **Provider *instances*, not providers.** One driver kind, N configured instances, each with its own
  `CLAUDE_CONFIG_DIR`, env vars (with a sensitive/secret flag), binary path, display name, accent
  colour. That's how they do work/personal accounts, OpenRouter, and Claude Code Router. A thread can
  only switch to an instance in the same `continuation.groupKey`.
- **Capability probe** per instance: spawns a throwaway SDK query to read account email /
  subscription type / token source and the live slash-command list, cached 5 min.
- **Skills discovery** by scanning the filesystem (`<config>/skills`, `<cwd>/.agents/skills`,
  `<cwd>/.claude/skills`, later wins) because the SDK init handshake exposes skills only as slash
  commands without paths. Feeds a `$` picker in the composer.
- **Permission modes** as a product concept: Supervised / Auto-accept edits / Auto / Full access, set
  per thread from the composer, each provider mapping them onto its own approval + sandbox model.
- **Checkpointing**: every turn is bracketed by workspace checkpoints stored as hidden git refs, so
  per-turn diffs are exact and "revert this turn" reverts **both** the workspace and the provider
  conversation (`rollbackThread(threadId, numTurns)`).
- **Cheap-model text generation** per provider (`claude -p` with structured JSON output) for thread
  titles, branch names, commit messages, PR bodies.
- **Usage page** that rescans providers' local session history for cost/tokens/cache savings across
  connected environments.
- **Session reaper** at 30 min idle; **buffered assistant delivery** mode that spills at 24k chars
  and flushes at approval boundaries (mobile-friendly, fewer patches).

---

## 2. Where Loopyard actually stands

Being fair to ourselves — a lot of the hard part is done, and some of it is done *better*:

**We have that they don't:** containerised execution as the security boundary; real multiplayer
(PubSub fan-out, every view its own URL); the Operator altitude; ports/preview cluster management;
fork/integrate/delete as approval-gated agent tools; a durable message inbox that survives harness
death; harness-portable conversation memory (`recall_conversation` + `ResumeMessage` seeding);
disposable-harness recycling; quarantine / sagas / orphan + drift observability at `/system`.

**We have parity on:** the harness behaviour seam itself; ACP transport with `session/load` resume;
model list + live model switch (both wire dialects); questions round-trip via ACP form elicitation;
approvals; interrupt; idle reap; memory reclaim; rate-limit events; context-utilization warnings.

**Verified gaps** (read from the code today, not assumed):

| Gap | Evidence |
|---|---|
| Reasoning is **never persisted** | `Translator.do_step/3` `agent_thought_chunk` emits only `%Event.ThinkingDelta{}` (display-only). `%Event.Thinking{}` — the branch in `StreamHandler` that *does* persist a `role: :thinking` message — is never constructed on the ACP path. Reasoning vanishes on refresh. |
| Plan / todos thrown away | Translator emits `%Event.SystemEvent{subtype: :plan}`; `StreamHandler.process_event(%Event.SystemEvent{}, state)` returns `state` unchanged. |
| Slash commands / skills thrown away | Same: `subtype: :available_commands` is received and discarded. No composer picker. |
| No subagent surface | ACP has no task events and our translator has no concept of one. A `Task` spawn is an opaque tool call. |
| Permission mode hardcoded | `Harness.ACP.acp_permission_mode(_opts), do: :auto_allow`. No Supervised / auto-accept-edits. |
| Cost is always `$0`, output tokens are a guess | `Translator.finish/2`: `output_tokens: div(byte_size(full), 4)`, `cost_usd: 0.0`. Deliberate (documented) — but it means no spend visibility at all. |
| No per-turn diff, no checkpoint, no revert | `ChangeCounts` gives a ±N badge for the workspace; there is no per-turn diff and no rewind of workspace or conversation. |
| No hooks, compaction boundary, or model-reroute visibility | Not in ACP; not modelled. |
| One account per machine | `workstation-token-account-bound`: no provider-instance concept, so no work/personal split, no OpenRouter/router instance. |
| No usage/cost analytics | — |
| One vendor | Claude only. |

---

## 2b. What the pinned adapter already sends us (verified, not assumed)

Unpacked `@agentclientprotocol/claude-agent-acp@0.60.0` — the exact version pinned in
`priv/workspace-base/Dockerfile` — and read `dist/acp-agent.js`. It is far less lossy than the ACP
*spec* suggests, and we consume a fraction of it:

| Already on the wire | Where | We do |
|---|---|---|
| **Real dollar cost per turn** — `usage_update` carries `cost: {amount, currency}` sourced from the SDK's `total_cost_usd` | `sessionUpdate: "usage_update"` | read only `used`; ignore `cost` → permanent `$0` |
| **Session/permission modes** — `session/new` returns `modes: {currentModeId, availableModes}`; `session/set_mode` switches; `current_mode_update` notifies on agent-initiated changes. The adapter implements `default` / `acceptEdits` / `bypassPermissions` / **`plan`** | handshake + `session/update` | never read; hardcode `:auto_allow` |
| **Subagent attribution** — every subagent-owned update is stamped `_meta.claudeCode.parentToolUseId`, precisely so clients can keep it out of the top-level feed | `_meta` on `session/update` | ignored → subagent narration interleaves into the main transcript |
| Reasoning stream | `agent_thought_chunk` | streamed, never persisted |
| Plan / todos | `plan` update | translated, then discarded by `StreamHandler` |
| Slash commands + skills | `available_commands_update` | translated, then discarded |
| Compaction | emitted as plain `agent_message_chunk` prose ("Compacting…" / "Compacting completed.") | already visible — no work needed |
| Native tool name | `_meta.claudeCode.toolName` | ✅ consumed |
| Rate limits | `_meta["_claude/rateLimit"]` | ✅ consumed |
| Raw SDK frame passthrough | `_meta["_claude/sdkMessage"]` | unused — a free provenance feed for `/system/events` |

**This materially changes §3 and §4.** Cost, reasoning persistence, plan, slash commands, permission
modes *and* plan mode, and subagent attribution are all reachable **without a native dialect** —
they're translator and `StreamHandler` changes against a connection we already own. The native
dialect (Slice 4) buys hooks, `tool_progress` elapsed time, per-task usage rollups and
`ExitPlanMode`'s structured plan — a much smaller prize than it looked. Demote it accordingly:
**do §4a below first, and re-evaluate whether Slice 4 is ever worth it.**

### 4a. The cheap tier — ~1 file each, no new architecture

Ordered by value per unit of complexity. All of these live in
`Loopyard.Harness.ACP.Translator` + `ChatAgent.StreamHandler` + one card each.

1. **Read `cost` off `usage_update`.** Thread it onto `%Event.SessionResult{cost_usd:}`. Ends the
   permanent `$0` with an authoritative number, and retires the `byte_size/4` output-token guess as
   the thing anyone looks at. *Smallest change in the whole epic, biggest credibility win.*
2. **Persist reasoning.** Accumulate `agent_thought_chunk` the same way `Translator` already
   accumulates text; emit one `%Event.Thinking{}` in `finish/2`. `StreamHandler` and the `💭
   Reasoning` disclosure already exist and are already correct — they're just never fed.
3. **Stop dropping `SystemEvent`.** `:plan` → a live checklist card; `:available_commands` → agent
   state + a `/` picker. The data arrives on every session today.
4. **Session modes.** Copy the model-switcher pattern wholesale (`available_models` /
   `set_model` / optimistic display / revert-on-error → `available_modes` / `set_mode` /
   `current_mode_update`). Gets Supervised, auto-accept-edits **and plan mode** in one move.
5. **Subagent attribution.** Minimum viable is *not* an Agents panel: read
   `_meta.claudeCode.parentToolUseId` and nest attributed activity under its owning `Task` tool
   card instead of interleaving it. The roster (Slice 5) becomes optional polish afterwards.
6. **`_meta["_claude/sdkMessage"]` → `/system/events`.** Free provenance for debugging translation
   bugs, which is where the last three years of this kind of work actually goes.

## 3. The architectural call (decide this first)

**Proposal: keep `Loopyard.Harness` as the seam and run two dialects underneath it.**

```
                    Loopyard.Harness (behaviour — unchanged shape)
                                │
        ┌───────────────────────┴────────────────────────┐
   NATIVE dialect                                   ACP dialect
   full-fidelity, per-vendor                        generic, lowest-common-denominator
   ├── Harness.ClaudeNative  (new)                  ├── Harness.ACP (today, Claude)
   └── Harness.CodexNative   (later, app-server)    ├── Cursor, Grok, Gemini, OpenCode…
                                                    └── any future ACP agent, free
```

This is exactly t3code's answer, and the reasoning transfers: **ACP is the only door for most
vendors, and it is the wrong door for the one vendor we care most about.** ACP `session/update` has
no task events, no hooks, no cost, no todos-as-plan, no compaction boundary, and only a coarse
thought chunk. Every gap in §2 that says "not in ACP" is structural, not a missing patch.

### Options for the native Claude dialect

| | How | Fidelity | Cost |
|---|---|---|---|
| **A. `claude --output-format stream-json`** driven directly from Elixir over `docker exec -i` | Speak the CLI's stream-json wire protocol ourselves; `--input-format stream-json` for the multi-turn + control channel (`control_request`/`control_response`) that carries `canUseTool` and `setPermissionMode` | Full — the Agent SDK is a wrapper over this same wire | No new language in the stack. Needs a spike to confirm the control channel is usable without the SDK. **Recommended path to spike first.** |
| **B. Node sidecar in the workspace image** hosting `@anthropic-ai/claude-agent-sdk`, speaking a Loopyard-native NDJSON protocol over stdio | We own the sidecar; it's ~the ClaudeAdapter's job, minus the Effect | Full, and vendor-maintained | Adds a TS artifact to build, version and ship with `WorkContainer`. Fallback if (A)'s control channel is closed. |
| **C. Stay on ACP, push `_meta`** | `claude-agent-acp` already forwards `_meta["claudeCode"]["toolName"]` and `_meta["_claude/rateLimit"]` | Partial at best; we'd be lobbying upstream for each field | Cheapest, ceilinged low. Keep as the *generic* path, not the Claude path. |

Containment is unaffected by any of these — all three run inside the workspace container, which is
and stays the security boundary (`docs/SECURITY.md`).

**Non-negotiable:** whichever dialect, the UI keeps classifying by neutral kind
(`Loopyard.Agent.ToolKind`), never by raw tool name. Adding the native dialect must not add a single
name string-match in `lib/loopyard_web`.

---

## 4. The epic

Ordered so each slice ships something a human can see. Slices 1–2 are worth doing **even if we never
build the native dialect**, because the data is already arriving and being dropped on the floor.

### Slice 1 — Stop throwing away what ACP already gives us *(small, do now)*

- Persist reasoning: emit `%Event.Thinking{}` at turn end alongside the final `%Event.Text{}`, same
  accumulate-then-commit pattern the translator already uses for text. Reasoning survives refresh.
- Route `%Event.SystemEvent{subtype: :plan}` to a real plan/todo card (band anatomy, `StreamCard`),
  updated in place across the turn rather than appended.
- Route `:available_commands` into agent state and surface it — minimum a `/` picker in the composer.
- **Acceptance:** refresh a page mid-turn and the reasoning block is still there; a `TodoWrite`-driven
  turn shows a live checklist; `/` in the composer lists the session's real commands.

### Slice 2 — Permission modes as a product concept

- Four modes on the agent (Supervised / Auto-accept edits / Auto / Full access), set per agent from
  the composer, persisted, multiplayer-visible.
- ACP mapping: `session/set_mode` where the adapter advertises it; approval round-trip through the
  existing `Harness.Approvals` + `ApprovalActions` (both models already exist — this is wiring, not
  new UI).
- Default stays Full access for worktree/fork workspaces; a canonical Local project may want
  Supervised.
- **Acceptance:** flipping to Supervised makes the next `Bash` call raise an approval card; flipping
  back doesn't.

### Slice 3 — Widen `Loopyard.Agent.Event` to the vocabulary we actually need

Do this *before* the native dialect so the dialect has somewhere to write. Proposed additions, kept
deliberately smaller than t3code's 45:

- `%Event.Reasoning{}` (finalized; `ThinkingDelta` stays the live channel)
- `%Event.Plan{entries}` — replaces the `SystemEvent` hack
- `%Event.Task{}` / `%Event.TaskProgress{}` / `%Event.TaskDone{}` — subagents, carrying the linkage
  fields (id, parent, type, title, model, effort, usage) **repeated on every row**, per t3code's
  hard-won note
- `%Event.Usage{}` — real token snapshot (used / max / input / cached / output / reasoning) and cost
  when the harness reports it
- `%Event.Compaction{}` — pre/post tokens, so the transcript shows where context was dropped
- `%Event.Hook{}` — optional, cheap once native
- `raw:` provenance field on every event, feeding `/system/events`

Corollary: `ToolKind` grows the kinds the new items imply (`:web_search`, `:image_view`, …) — still
one place, still no name matching in the view layer.

### Slice 4 — Native Claude dialect

Spike option (A) first; fall back to (B). Deliverable is `Harness.ClaudeNative` implementing the
existing behaviour, selected per-agent by config, with `Harness.ACP` still the default until the new
one is proven on a real workspace for a week.

Unlocks, in rough value order: **real cost and token accounting**; the subagent roster; hooks;
compaction boundary; `tool_progress` elapsed-time and one-line summaries; `ExitPlanMode` plan
approval; live `setPermissionMode` without a session restart; model-reroute notices.

**Acceptance:** run the same prompt on both dialects; the native one shows a non-zero dollar figure
that matches `/cost`, a subagent roster for a `Task`-spawning prompt, and identical tool cards.

### Slice 5 — Subagent surface (the "Agents panel")

Once `Event.Task*` exists: a right-rail roster of the fleet an agent spawned, rows stable in spawn
order, three fixed lines each (identity / activity / metrics) so live data never changes row height.
Subagent-owned narration must **not** interleave into the main transcript — re-home by
`parentToolUseId`. (t3code learned both rules the hard way; their `AgentsPanel.tsx` header comments
are the spec.)

Fits Loopyard's altitude model naturally: the Operator already reasons about a fleet, this is the
same idea one level down.

### Slice 6 — Turn checkpoints, diffs and revert

Per-turn workspace snapshot as a hidden git ref in the code volume, captured on turn start and
completion. Gives: an exact per-turn diff card, "revert this turn" that rolls back workspace **and**
conversation, and a much better `ChangeCounts`. Interacts with fork/integrate — worth its own design
note before building.

### Slice 7 — Provider instances (multi-account)

Named instances per driver kind, each with binary path, config dir, env vars (sensitive values via
the existing secret store), display name, accent colour. Solves the account-bound-token problem, plus
OpenRouter / Claude Code Router / a second account, and is a precondition for "this workspace runs
Codex, that one runs Claude". Switching instances mid-conversation drops the native session id and
falls back to our portable `ResumeMessage` seeding — which we already have and t3code does not.

### Slice 8 — Codex, then the ACP field

**Verified against `@agentclientprotocol/codex-acp@1.6.0` (unpacked, read):** this is a near drop-in
for `Harness.ACP` as it stands today.

| What we need | What codex-acp does |
|---|---|
| Model list + switch for the sidebar picker | advertises **both** `availableModels`/`currentModelId` **and** `configOptions` — the exact two dialects `Connection.Models.extract_models/1` already normalizes |
| Resume across restart | `loadSession` — our `session/load` path works unchanged |
| Reasoning | `agent_thought_chunk` |
| Tokens | `usage_update` |
| Slash commands / skills | `available_commands_update`, incl. `/status`, `/compact`, `/review`, `/skills` |
| Permission modes | `session/set_mode` + `availableModes`; `INITIAL_AGENT_MODE` = `read-only` \| `agent` \| `agent-full-access` |
| Our control-plane tools | client-provided MCP servers over **stdio and HTTP** — the ACP MCP bridge spec we already build |
| Subagents | launched as standard ACP tool calls, detail in `_meta.codex.subagent` |
| Binary | bundles `@openai/codex` as a dependency — one `npm install -g`, no separate codex install |
| Credentials | `CODEX_API_KEY` / `OPENAI_API_KEY` env (plus ChatGPT login; set `NO_BROWSER=1` for our headless containers) |

So the work is: add the package to `priv/workspace-base/Dockerfile`, teach `Harness.ACP` **which
adapter binary to exec** (today it's hardcoded `claude-agent-acp`), and add `OPENAI_API_KEY` to the
credential keys. Everything downstream — connection, translator, resume, MCP bridge, questions,
approvals, model switcher — is already harness-agnostic.

### Slice 8a — The harness + model picker (the headline)

The agent sidebar already has a model switcher driven by `available_models` / `set_model`. Make it a
**harness + model** control: one grouped list ("Claude — Opus 4.8, Sonnet 5 · Codex — GPT-5.6 …").

- Same-harness pick → today's live `session/set_model`, no restart.
- Cross-harness pick → `restart_session(id, :harness)` with the new adapter. **The conversation
  survives**: this is precisely what harness-portable memory was built for — `ResumeMessage.build/1`
  seeding + `recall_conversation`, with the native session id dropped because the new harness can't
  see it. That machinery exists and is documented in CLAUDE.md; this slice is its first real payoff.
- Availability is credential-gated: a harness with no usable credential shows disabled with the
  reason, not hidden.

### Slice 8b — Credentials per harness

- **Codex** has two doors: the app-server JSON-RPC protocol (what t3code implements, richest) and an
  official ACP adapter, `@agentclientprotocol/codex-acp`. **Start with codex-acp** — it drops into the
  existing `Harness.ACP` connection with an image change and a driver-kind, and gets us a second
  vendor in days rather than months. Promote to a native `Harness.CodexNative` only if the fidelity
  gap bites the same way it does for Claude.
- **Then everything else on ACP for free**: Cursor, Grok, Gemini CLI, Copilot CLI, OpenCode — the ACP
  Agent Registry has been live in Zed and JetBrains since Jan 2026, and each is an adapter binary in
  `priv/workspace-base/Dockerfile` plus a driver entry.
- Per-vendor differences (model lists, effort/reasoning options, mode names) go behind a small
  capability descriptor, per t3code's `ProviderOptionDescriptor` (select/boolean options with
  defaults, per model) rather than per-vendor branches in the UI.

Credentials are the gating concern, and we are further along than it looks: `Workstation.Env`
already owns a credential env written to `~/.loopyard/env` and pushed into containers,
`@credential_keys` already lists `CLAUDE_CODE_OAUTH_TOKEN` / `ANTHROPIC_API_KEY`, and
`Workstation.Integration` already has an `OPENAI_API_KEY` entry with a setup flow. What's missing is
only that the env is **global to the workstation**, so there is no work/personal split and no "this
workspace runs Codex on my API key". Lightest version of t3code's provider-instances idea:

1. Add the new keys (`OPENAI_API_KEY` / `CODEX_API_KEY`, `NO_BROWSER=1`) to the existing integration
   list — Codex auth then works the day the adapter lands, with zero new plumbing.
2. Later, and only if wanted: per-workspace overrides layered over the workstation env, reusing
   `Loopyard.Secrets` for the values. That is the whole of "provider instances" for our purposes —
   we do not need t3code's `CLAUDE_CONFIG_DIR`-per-instance machinery, because our isolation
   boundary is the container, not a config directory.

### Slice 9 — Cheap-model side work

A `TextGeneration`-equivalent: one-shot `claude -p` / `codex exec` with structured output, on a small
model, for agent/thread titles, branch names, commit messages, PR bodies. Small, high-visibility,
and it makes the Operator's digest much better.

---

## 5. Explicit non-goals

Things t3code has that we should **not** copy:

- **Event-sourced SQLite orchestration.** Our ETF log + ETS + PubSub is the equivalent and the
  workspace-affinity model makes a shared DB unnecessary. Don't import a decider/projector.
- **Host-process harnesses.** Their execution model is "the server is the boundary". Ours is "the
  container is the boundary", which is stronger. Every dialect above runs in-container.
- **Their client stack.** Effect Atom + React + three apps. We're server-driven LiveView by
  conviction (`client-is-scarce-server-first`), and the native-wrapper trajectory is URL-rooted modes.
- **Buffered assistant delivery.** Our delta coalescing (`@delta_flush_ms`) already solves the
  patch-storm problem server-side.
- **A usage analytics page**, at least not early. Real per-turn cost (Slice 4) is the 80%.

---

## 6. Open questions for Brad

1. **Native-dialect appetite.** Given §2b, is it needed at all? Ship §4a first (days, no new
   architecture), then judge whether hooks + `tool_progress` + per-task usage justify a whole second
   dialect. My read: probably not this quarter.
2. **Codex priority.** Second vendor via `codex-acp` early (cheap, proves the seam, ships a headline)
   — or finish Claude fidelity first? They're independent; Slice 8 can run in parallel with 4–5.
3. **Permission modes** — do we want them at all, given the container is already the boundary and
   `simplest-fast-show-status` says don't over-build? My read: yes for canonical Local projects (the
   checkout is real), no default change for forks.
4. **Checkpoints (Slice 6)** — genuinely useful, or does fork/integrate already cover the
   "undo a bad turn" need well enough?

---

## Reference map (t3code paths worth reading before implementing)

| Concern | Path |
|---|---|
| Neutral event vocabulary | `packages/contracts/src/providerRuntime.ts` |
| Adapter contract | `apps/server/src/provider/Services/ProviderAdapter.ts` |
| Claude adapter | `apps/server/src/provider/Layers/ClaudeAdapter.ts` |
| Claude probe / models / slash commands | `apps/server/src/provider/Layers/ClaudeProvider.ts` |
| Skills discovery | `apps/server/src/provider/Drivers/ClaudeSkills.ts` |
| Codex app-server client | `packages/effect-codex-app-server/` |
| Generic ACP client | `packages/effect-acp/`, `apps/server/src/provider/acp/` |
| Provider architecture doc | `docs/internals/providers.md`, `docs/internals/overview.md` |
| Glossary (thread/turn/activity/checkpoint) | `docs/internals/glossary.md` |
| Permission modes as product | `docs/user/permission-modes.md` |
| Multi-account Claude | `docs/user/providers-claude.md` |
| Subagent panel rules | `apps/web/src/components/AgentsPanel.tsx` (header comment) |
