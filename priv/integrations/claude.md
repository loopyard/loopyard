# Claude

Run Claude Code in the box on your Claude subscription. The **"Run this on your
Mac"** command above does the whole transfer — you shouldn't need anything here.

It reads your login from the macOS **Keychain** (item `Claude Code-credentials`,
with a `~/.claude/.credentials.json` fallback on Linux) and pushes it in, **plus**
a minimal `~/.claude.json` so *interactive* `claude` doesn't re-run its login flow.

> **Why not just `cat ~/.claude/.credentials.json`?** On macOS that file doesn't
> exist — Claude keeps the creds in the Keychain. And the credentials *alone* make
> `claude -p` work but leave *interactive* `claude` asking you to log in, because
> it also checks `~/.claude.json` for onboarding state. The command above handles
> both; a plain file copy only works on Linux.

## Or a long-lived token (durable, env)

On your Mac (needs a browser): `claude setup-token` → paste it into the
`CLAUDE_CODE_OAUTH_TOKEN` slot under **Other ways**. Durable (no hourly refresh)
but needs a **Restart** to apply.

## Check it

In the console: `claude -p "say ok"` (should reply), or `test -f ~/.claude/.credentials.json`.
