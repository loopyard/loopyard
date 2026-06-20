# Claude

Run Claude Code in the box on your Claude subscription (Pro/Max/Team) — no API key.

## Reconnect from your phone (`claude setup-token`)

The path that needs **no laptop**. When Anthropic expires your login while you're
out, you can re-auth entirely from your phone:

1. Tap **▶ claude setup-token** under *Use the terminal* below. It runs in the box
   and prints an **authorization URL**.
2. Open that URL **on your phone**, sign in, approve.
3. The browser shows a **code** (the box can't catch the local callback — expected
   in a container). Paste it back into the terminal at the `Paste code here`
   prompt.
4. `setup-token` prints a **token** (good for one year). Copy it into the
   **`CLAUDE_CODE_OAUTH_TOKEN`** box under *Set a token*, and **Restart**.

That's it — a full re-auth with nothing but the phone in your hand.

`CLAUDE_CODE_OAUTH_TOKEN` is the env var Claude Code reads for non-interactive use;
it takes precedence over `~/.claude/.credentials.json` and needs **no** `~/.claude`
files at all. The interactive-login token (`.credentials.json`) is short-lived and
401s within hours — this avoids that treadmill.

> Don't run `claude -p --bare` in the box — bare mode ignores the token. Plain `claude -p "…"` is fine.

## Quick start (expires): transfer your Mac login

The bulk **"Run this on your Mac"** command copies your *current* Claude login
(from the macOS Keychain item `Claude Code-credentials`) into `~/.claude`, plus a
minimal `~/.claude.json` so interactive `claude` doesn't re-run its login flow.
Enough to make `claude -p` work *right now* — but that token is short-lived. Use
the phone-native long-lived token above for anything lasting.

## Check it

In the console: `claude -p "say ok"` (should reply). The card shows **Connected**
once `CLAUDE_CODE_OAUTH_TOKEN` is set.
