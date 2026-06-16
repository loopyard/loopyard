# Claude

Run Claude Code in the box on your Claude subscription (Pro/Max/Team) — no API key.

## Recommended: a long-lived token (`claude setup-token`)

[Anthropic's documented path](https://code.claude.com/docs/en/authentication.md#generate-a-long-lived-token)
for headless/container use, and the one you want for a box you keep around:

1. **On your Mac** (needs a browser): `claude setup-token` → approve in the browser → copy the token it prints. Good for **one year**.
2. Paste it into the **`CLAUDE_CODE_OAUTH_TOKEN`** env slot (Environment page) — or push it.
3. **Restart the machine** — it's written to `~/.profile` at boot and the login shell sources it, so both the agent and the console see it.

`CLAUDE_CODE_OAUTH_TOKEN` is the env var Claude Code reads for non-interactive use;
it takes precedence over `~/.claude/.credentials.json` and needs **no** `~/.claude`
files at all. The token from interactive `claude login` (`.credentials.json`) is
short-lived and 401s within hours — this avoids that treadmill.

> Don't run `claude -p --bare` in the box — bare mode ignores the token. Plain `claude -p "…"` is fine.

## Quick start (expires): transfer your Mac login

The bulk **"Run this on your Mac"** command also copies your current Claude login
(from the macOS Keychain item `Claude Code-credentials`) into `~/.claude`, plus a
minimal `~/.claude.json` so interactive `claude` doesn't re-run its login flow.
Enough to make `claude -p` work *right now* — but that token is short-lived. Use
the long-lived token above for anything lasting.

## Check it

In the console: `claude -p "say ok"` (should reply). The card shows **Connected**
once `CLAUDE_CODE_OAUTH_TOKEN` is set.
