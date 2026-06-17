# ACP + reliability — "drive from an iPhone for a week"

The acceptance test, verbatim: **run agents reliably from an iPhone exclusively
for a week, no laptop.** That single bar forces everything — reliability,
reconnection, and a version-stable harness — to actually work, not just compile.
Voice (the wrist endgame) comes *after* this lands.

## Why ACP is the linchpin (do it first)

The fragility that wedged us all session — version skew, silent message drops,
host-side CLI deadlocks — is the cost of **screen-scraping a vendor CLI through an
SDK that lags its format**. ACP replaces that with a *stable, versioned protocol*:
the real harness speaks ACP, Loopyard speaks ACP, neither parses the other's
private message format. So ACP is **item 2 AND the biggest single win for item 1**.

### ACP status (2026-06-16)

Aligned now:
- Base image ships `@zed-industries/claude-code-acp@0.16.2` (`priv/workspace-base/Dockerfile`).
- `Backend.ACP` supports in-container mode (`docker exec -i <work> claude-code-acp`).
- **Auth unblocked:** the durable `CLAUDE_CODE_OAUTH_TOKEN` lives in the identity
  home volume, sourced by a login shell.
- **Fixed today:** `Acp.docker_exec_cmd/2` now launches the adapter via
  `sh -c '. "$HOME/.profile"; exec claude-code-acp'` so the token is in scope
  (bare `docker exec` would 401).

Remaining to "ACP end-to-end":
1. **Boot one ACP agent live** — start a `ChatAgent` with `backend: Backend.ACP`,
   `container: loopyard-<ws>-work`, send a prompt, confirm it **streams a real
   reply** (auth works) and **runs a tool** in the container. The validation gate.
2. **System prompt path** — in-container mode writes the prompt as `CLAUDE.md` into
   the code volume (claude-code-acp has no `append_system_prompt`). Confirm it's
   picked up.
3. **Make ACP the default backend** for new agents (config flip), keep
   `Backend.ClaudeCode` as fallback.
4. **Native interrupt** — wire ACP `cancel` to a chat "Stop" (the real turn-taking).

## Reliability (item 1) — toward the week

Landed this session:
- Boot: 30s `:start_agent` timeout (no spurious rollback); `remove_agent`
  terminates the process (no zombie resurrection).
- Execution: reboot-on-wedge (stream timeout → restart CLI with resume, keep
  chat); terminal UTF-8 crash-proofing (no silent channel crash).
- Creds: durable token, files-in-`$HOME`, login-shell delivery.

Remaining:
- **Surface failures loudly.** Silent drops (SDK parse skips) and crashes must hit
  `/system/events` + an inline chat marker, never just a buried log — you can't see
  logs from a phone. (ACP removes most of the parse-skip class.)
- **Reconnect-replay.** Borrow OpenCode's model: a seq/cursor on events so a phone
  that dropped network replays only the gap from the ETF log, not the whole
  session. This is what makes phone-drop cheap.
- **Test isolation.** The flaky `ChatAgent.*` suite (shared workspace, agents.log
  churn) masks real signal — fix isolation so "green" means something.

## The gate: a soak test (don't claim "reliable" without a number)

Before betting a week: a harness that **boots + runs a real turn through N agents
in a loop until it's boring** — `100/100 boots clean, 100/100 turns streamed,
100/100 reconnects intact`. Run it against the ACP backend. That number is the
go/no-go for the iPhone week, not vibes.

## iPhone surface checks (the "no laptop" part)

- LiveView chat usable on iOS Safari (dvh viewports already handled for the
  workstation pages — extend to the agent chat).
- Reconnect on backgrounding / network drop is seamless (the replay work above).
- Everything driveable from the phone: create agent, message, review diffs,
  approve fork/integrate, restart a wedged agent.

## Build order

1. **ACP end-to-end live** (boot + prompt + tool + resume). ← the linchpin, next.
2. Make ACP the default; ClaudeCode fallback.
3. Surface failures loudly (`/system/events` + chat markers).
4. Reconnect-replay (seq/cursor).
5. Soak test → the trust number.
6. iPhone surface pass.
7. ACP `cancel` → "Stop" (turn-taking).
